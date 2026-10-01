"""Separate SQLite DB mirroring MFDS drug product permission data."""

from __future__ import annotations

import html
import re
import sqlite3
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

from app.core.config import MFDS_DRUG_PERMISSION_DB_PATH
from app.services.matching.chosung import is_chosung_query, to_chosung

DB_PATH = MFDS_DRUG_PERMISSION_DB_PATH


SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS products (
    item_seq TEXT PRIMARY KEY,
    item_name TEXT NOT NULL,
    name_compact TEXT NOT NULL,
    name_chosung TEXT,
    item_eng_name TEXT,
    entp_name TEXT,
    entp_eng_name TEXT,
    entp_seq TEXT,
    entp_no TEXT,
    item_permit_date TEXT,
    induty TEXT,
    prduct_type TEXT,
    prduct_prmisn_no TEXT,
    prdlst_stdr_code TEXT,
    spclty_pblc TEXT,
    permit_kind_code TEXT,
    cancel_name TEXT,
    cancel_date TEXT,
    edi_code TEXT,
    item_ingr_name TEXT,
    item_ingr_cnt TEXT,
    bizrno TEXT,
    big_prdt_img_url TEXT,
    etc_otc_code TEXT,
    chart TEXT,
    bar_code TEXT,
    material_name TEXT,
    storage_method TEXT,
    valid_term TEXT,
    pack_unit TEXT,
    main_item_ingr TEXT,
    ingr_name TEXT,
    atc_code TEXT,
    ee_doc_data TEXT,
    ud_doc_data TEXT,
    nb_doc_data TEXT,
    efficacy_text TEXT,
    usage_text TEXT,
    caution_text TEXT,
    detail_synced INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_products_name_compact
    ON products(name_compact);
CREATE INDEX IF NOT EXISTS idx_products_item_name
    ON products(item_name);
CREATE INDEX IF NOT EXISTS idx_products_detail_synced
    ON products(detail_synced);
"""


def get_permission_connection() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, timeout=60)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA busy_timeout=60000")
    return conn


def initialize_permission_db() -> Path:
    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    conn = get_permission_connection()
    try:
        conn.executescript(SCHEMA_SQL)
        columns = {
            row[1] for row in conn.execute("PRAGMA table_info(products)").fetchall()
        }
        if "name_chosung" not in columns:
            conn.execute("ALTER TABLE products ADD COLUMN name_chosung TEXT")
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_products_name_chosung "
            "ON products(name_chosung)"
        )
        conn.commit()
        backfill_name_chosung(conn)
    finally:
        conn.close()
    return Path(DB_PATH)


def backfill_name_chosung(conn: sqlite3.Connection | None = None) -> int:
    own = conn is None
    conn = conn or get_permission_connection()
    try:
        rows = conn.execute(
            """
            SELECT item_seq, item_name FROM products
            WHERE name_chosung IS NULL OR name_chosung = ''
            """
        ).fetchall()
        for row in rows:
            conn.execute(
                "UPDATE products SET name_chosung = ? WHERE item_seq = ?",
                (to_chosung(row["item_name"]), row["item_seq"]),
            )
        conn.commit()
        return len(rows)
    finally:
        if own:
            conn.close()


def compact_name(value: str) -> str:
    return "".join(str(value or "").casefold().split())


PINNED_ITEM_SEQ = {
    "휴온스시메티딘정": "200403137",
    "휴온스시메티딘정200밀리그램": "200403137",
    "휴온스시메티딘정200밀리그람": "200403137",
}


def _pinned_item_seq(name: str) -> str | None:
    compact = compact_name(name)
    if compact in PINNED_ITEM_SEQ:
        return PINNED_ITEM_SEQ[compact]
    stripped = re.sub(
        r"\d+(?:\.\d+)?(?:밀리그램|밀리그람|mg).*$",
        "",
        compact,
        flags=re.IGNORECASE,
    )
    return PINNED_ITEM_SEQ.get(stripped)


_DOC_HEADING_TITLES = {
    "효능효과",
    "용법용량",
    "사용상의 주의사항",
    "사용상 주의사항",
    "저장방법",
    "유효기간",
}


def xml_doc_to_text(value: Any) -> str:
    text = str(value or "")
    if not text or text == "None":
        return ""

    def _piece(raw: str) -> str:
        cleaned = html.unescape(str(raw or ""))
        cleaned = re.sub(r"<[^>]+>", " ", cleaned)
        cleaned = cleaned.replace("\xa0", " ")
        return " ".join(cleaned.split()).strip()

    parts: list[str] = []
    for raw_title in re.findall(r'\btitle="([^"]*)"', text):
        title = _piece(raw_title)
        if not title or title in _DOC_HEADING_TITLES:
            continue
        if title not in parts:
            parts.append(title)
    for raw_cdata in re.findall(r"<!\[CDATA\[(.*?)\]\]>", text, flags=re.S):
        body = _piece(raw_cdata)
        if not body or body in parts:
            continue
        parts.append(body)
    if parts:
        return " ".join(parts)
    leftover = _piece(re.sub(r"<[^>]+>", " ", text))
    return leftover


def xml_doc_section_to_text(value: Any, titles: tuple[str, ...]) -> str:
    """Return text only from explicitly titled sections of an MFDS XML document."""
    raw = str(value or "").strip()
    if not raw or raw == "None":
        return ""
    try:
        root = ET.fromstring(raw)
    except ET.ParseError:
        return ""

    wanted = tuple(title.casefold() for title in titles)
    sections: list[str] = []
    for element in root.iter():
        title = str(element.attrib.get("title") or "").casefold()
        if not any(keyword in title for keyword in wanted):
            continue
        text = " ".join(" ".join(element.itertext()).split())
        if text and text not in sections:
            sections.append(text)
    return " ".join(sections)


def backfill_plain_texts(conn: sqlite3.Connection | None = None) -> int:
    own = conn is None
    conn = conn or get_permission_connection()
    try:
        rows = conn.execute(
            """
            SELECT item_seq, ee_doc_data, ud_doc_data, nb_doc_data
            FROM products
            WHERE detail_synced = 1
            """
        ).fetchall()
        updated = 0
        for row in rows:
            efficacy = xml_doc_to_text(row["ee_doc_data"]) or None
            usage = xml_doc_to_text(row["ud_doc_data"]) or None
            caution = xml_doc_to_text(row["nb_doc_data"]) or None
            conn.execute(
                """
                UPDATE products
                SET efficacy_text=?, usage_text=?, caution_text=?
                WHERE item_seq=?
                """,
                (efficacy, usage, caution, row["item_seq"]),
            )
            updated += 1
        conn.commit()
        return updated
    finally:
        if own:
            conn.close()


def upsert_list_item(conn: sqlite3.Connection, item: dict[str, Any]) -> None:
    item_seq = str(item.get("ITEM_SEQ") or "").strip()
    item_name = str(item.get("ITEM_NAME") or "").strip()
    if not item_seq or not item_name:
        return
    conn.execute(
        """
        INSERT INTO products (
            item_seq, item_name, name_compact, name_chosung, item_eng_name, entp_name,
            entp_eng_name, entp_seq, entp_no, item_permit_date, induty,
            prduct_type, prduct_prmisn_no, prdlst_stdr_code, spclty_pblc,
            permit_kind_code, cancel_name, cancel_date, edi_code,
            item_ingr_name, item_ingr_cnt, bizrno, big_prdt_img_url,
            updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(item_seq) DO UPDATE SET
            item_name=excluded.item_name,
            name_compact=excluded.name_compact,
            name_chosung=excluded.name_chosung,
            item_eng_name=excluded.item_eng_name,
            entp_name=excluded.entp_name,
            entp_eng_name=excluded.entp_eng_name,
            entp_seq=excluded.entp_seq,
            entp_no=excluded.entp_no,
            item_permit_date=excluded.item_permit_date,
            induty=excluded.induty,
            prduct_type=excluded.prduct_type,
            prduct_prmisn_no=excluded.prduct_prmisn_no,
            prdlst_stdr_code=excluded.prdlst_stdr_code,
            spclty_pblc=excluded.spclty_pblc,
            permit_kind_code=excluded.permit_kind_code,
            cancel_name=excluded.cancel_name,
            cancel_date=excluded.cancel_date,
            edi_code=excluded.edi_code,
            item_ingr_name=excluded.item_ingr_name,
            item_ingr_cnt=excluded.item_ingr_cnt,
            bizrno=excluded.bizrno,
            big_prdt_img_url=excluded.big_prdt_img_url,
            updated_at=CURRENT_TIMESTAMP
        """,
        (
            item_seq,
            item_name,
            compact_name(item_name),
            to_chosung(item_name),
            _text(item.get("ITEM_ENG_NAME")),
            _text(item.get("ENTP_NAME")),
            _text(item.get("ENTP_ENG_NAME")),
            _text(item.get("ENTP_SEQ")),
            _text(item.get("ENTP_NO")),
            _text(item.get("ITEM_PERMIT_DATE")),
            _text(item.get("INDUTY")),
            _text(item.get("PRDUCT_TYPE")),
            _text(item.get("PRDUCT_PRMISN_NO")),
            _text(item.get("PRDLST_STDR_CODE")),
            _text(item.get("SPCLTY_PBLC")),
            _text(item.get("PERMIT_KIND_CODE")),
            _text(item.get("CANCEL_NAME")),
            _text(item.get("CANCEL_DATE")),
            _text(item.get("EDI_CODE")),
            _text(item.get("ITEM_INGR_NAME")),
            _text(item.get("ITEM_INGR_CNT")),
            _text(item.get("BIZRNO")),
            _text(item.get("BIG_PRDT_IMG_URL")),
        ),
    )


def update_detail_item(conn: sqlite3.Connection, item_seq: str, item: dict[str, Any]) -> None:
    efficacy = xml_doc_to_text(item.get("EE_DOC_DATA"))
    usage = xml_doc_to_text(item.get("UD_DOC_DATA"))
    caution = xml_doc_to_text(item.get("NB_DOC_DATA"))
    conn.execute(
        """
        UPDATE products SET
            etc_otc_code=?,
            chart=?,
            bar_code=?,
            material_name=?,
            storage_method=?,
            valid_term=?,
            pack_unit=?,
            main_item_ingr=?,
            ingr_name=?,
            atc_code=?,
            ee_doc_data=?,
            ud_doc_data=?,
            nb_doc_data=?,
            efficacy_text=?,
            usage_text=?,
            caution_text=?,
            detail_synced=1,
            updated_at=CURRENT_TIMESTAMP
        WHERE item_seq=?
        """,
        (
            _text(item.get("ETC_OTC_CODE")),
            _text(item.get("CHART")),
            _text(item.get("BAR_CODE")),
            _text(item.get("MATERIAL_NAME")),
            _text(item.get("STORAGE_METHOD")),
            _text(item.get("VALID_TERM")),
            _text(item.get("PACK_UNIT")),
            _text(item.get("MAIN_ITEM_INGR")),
            _text(item.get("INGR_NAME")),
            _text(item.get("ATC_CODE")),
            _text(item.get("EE_DOC_DATA")),
            _text(item.get("UD_DOC_DATA")),
            _text(item.get("NB_DOC_DATA")),
            efficacy or None,
            usage or None,
            caution or None,
            item_seq,
        ),
    )


def search_permission_names(query: str, limit: int = 10) -> list[str]:
    raw = (query or "").strip()
    if not raw:
        return []

    # 초성만 입력: ㅌㄹㄴ → 타이레놀(ㅌㅇㄹㄴ)처럼 모음을 건너뛴 입력도 허용
    if is_chosung_query(raw):
        chosung = "".join(raw.split())
        if len(chosung) < 1:
            return []
        # ㅌㄹㄴ → ㅌ%ㄹ%ㄴ%  (사이 초성 허용)
        loose = "%".join(chosung) + "%"
        conn = get_permission_connection()
        try:
            backfill_name_chosung(conn)
            rows = conn.execute(
                """
                SELECT item_name FROM products
                WHERE name_chosung LIKE ? OR name_chosung LIKE ?
                ORDER BY
                    CASE WHEN name_chosung LIKE ? THEN 0 ELSE 1 END,
                    LENGTH(name_chosung),
                    item_name
                LIMIT ?
                """,
                (f"{chosung}%", loose, f"{chosung}%", limit),
            ).fetchall()
            return [str(row["item_name"]) for row in rows]
        finally:
            conn.close()

    needle = compact_name(raw)
    if len(needle) < 2:
        return []
    conn = get_permission_connection()
    try:
        rows = conn.execute(
            """
            SELECT item_name FROM products
            WHERE name_compact LIKE ? OR name_compact LIKE ?
            ORDER BY
                CASE WHEN name_compact LIKE ? THEN 0 ELSE 1 END,
                LENGTH(name_compact),
                item_name
            LIMIT ?
            """,
            (f"{needle}%", f"%{needle}%", f"{needle}%", limit),
        ).fetchall()
        return [str(row["item_name"]) for row in rows]
    finally:
        conn.close()


def find_permission_product(name: str) -> dict[str, Any] | None:
    """이름으로 허가 제품을 찾는다. 임의 LIKE로 다른 약을 끌어오지 않는다."""
    from app.services.matching.name_matcher import _medicine_key, match_medicine_name

    compact = compact_name(name)
    if not compact:
        return None
    query_key = _medicine_key(name)
    conn = get_permission_connection()
    try:
        pinned_seq = _pinned_item_seq(name)
        if pinned_seq:
            pinned = conn.execute(
                "SELECT * FROM products WHERE item_seq = ?",
                (pinned_seq,),
            ).fetchone()
            if pinned is not None:
                return dict(pinned)

        row = conn.execute(
            """
            SELECT * FROM products
            WHERE name_compact = ?
            ORDER BY detail_synced DESC, item_seq
            LIMIT 1
            """,
            (compact,),
        ).fetchone()
        if row is not None:
            return dict(row)

        # 접두 일치 후보만 모아, 약품명 매칭(0.90/키 동일)으로 확정
        rows = conn.execute(
            """
            SELECT * FROM products
            WHERE name_compact LIKE ?
            ORDER BY LENGTH(name_compact), detail_synced DESC, item_seq
            LIMIT 20
            """,
            (f"{compact}%",),
        ).fetchall()
        if not rows and query_key:
            rows = conn.execute(
                """
                SELECT * FROM products
                WHERE name_compact LIKE ?
                ORDER BY LENGTH(name_compact), detail_synced DESC, item_seq
                LIMIT 20
                """,
                (f"{query_key}%",),
            ).fetchall()
        if not rows:
            return None
        labels = [str(r["item_name"] or "") for r in rows]
        match = match_medicine_name(name, labels, similar=False)
        if not match.matched_name:
            return None
        for r in rows:
            if str(r["item_name"] or "") == match.matched_name:
                return dict(r)
        return None
    finally:
        conn.close()


def find_permission_product_by_item_seq(item_seq: str) -> dict[str, Any] | None:
    """품목기준코드로 로컬 허가정보를 정확히 조회한다."""
    code = str(item_seq or "").strip()
    if not code or not Path(DB_PATH).is_file():
        return None
    conn = get_permission_connection()
    try:
        row = conn.execute(
            "SELECT * FROM products WHERE item_seq = ?",
            (code,),
        ).fetchone()
        return dict(row) if row is not None else None
    finally:
        conn.close()


def product_to_medicine(row: dict[str, Any]) -> dict[str, Any]:
    from app.services.pharmacist.ingredient import clean_ingredient_text
    from app.services.pharmacist.efficacy_display import display_efficacy_text

    # 주성분 우선. ingr_name은 포비돈·유당 같은 부형제까지 섞여 있다.
    ingredient = clean_ingredient_text(
        row.get("main_item_ingr")
        or row.get("item_ingr_name")
        or row.get("ingr_name")
        or row.get("material_name")
    ) or None
    efficacy = row.get("efficacy_text") or xml_doc_to_text(row.get("ee_doc_data"))
    usage = row.get("usage_text") or xml_doc_to_text(row.get("ud_doc_data"))
    cautions = row.get("caution_text") or xml_doc_to_text(row.get("nb_doc_data"))
    side_effects = xml_doc_section_to_text(
        row.get("nb_doc_data"),
        ("이상반응", "부작용"),
    )
    return {
        "medicine_code": row.get("item_seq"),
        "product_name": row.get("item_name"),
        "medicine_name": row.get("item_name"),
        "ingredient": ingredient,
        "manufacturer": row.get("entp_name"),
        "efficacy": efficacy or None,
        "usage": usage or None,
        "cautions": cautions or None,
        "precautions": cautions or None,
        "side_effects": side_effects or None,
        "storage": row.get("storage_method"),
        "image_url": row.get("big_prdt_img_url"),
        "source": "식약처 의약품 제품 허가정보",
    }


def count_stats() -> dict[str, int]:
    conn = get_permission_connection()
    try:
        total = conn.execute("SELECT COUNT(*) FROM products").fetchone()[0]
        detailed = conn.execute(
            "SELECT COUNT(*) FROM products WHERE detail_synced = 1"
        ).fetchone()[0]
        return {"total": int(total), "detailed": int(detailed)}
    finally:
        conn.close()


def _text(value: Any) -> str | None:
    text = str(value or "").strip()
    if not text or text == "None":
        return None
    return text
