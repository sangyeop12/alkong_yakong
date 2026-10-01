"""Retrieve verified MFDS drug permission medicine information."""

from __future__ import annotations

import re
import threading
from typing import Any


_detail_refresh_lock = threading.Lock()
_detail_refresh_thread: threading.Thread | None = None

from app.services.mfds_drug_permission.db import (
    find_permission_product,
    product_to_medicine,
)
from app.services.mfds_drug_permission.sync import (
    ensure_detail_for_product,
    lookup_permission_by_ocr_name,
)


def retrieve_official(
    drug_name: str,
    *,
    dosage_hint: str | float | None = None,
) -> dict[str, Any] | None:
    name = (drug_name or "").strip()
    if not name:
        return None
    try:
        from app.services.ocr.parser import product_search_name

        name = product_search_name(name)
        hangul = "".join(ch for ch in name if "가" <= ch <= "힣")
        if hangul and len(hangul) < 2:
            return None
    except Exception:
        pass

    # 1순위: 로컬 허가 DB (빠르고 안정적)
    local = _find_permission_local(name, dosage_hint=dosage_hint)
    if local:
        return local
    # 2순위: 실시간 식약처 허가 API. 짧은 타임아웃이라 실패해도 이 약만 미확인 처리된다.
    return _find_permission_live(name, dosage_hint=dosage_hint)


def _find_permission_local(
    name: str,
    *,
    dosage_hint: str | float | None = None,
) -> dict[str, Any] | None:
    try:
        row = find_permission_product(name)
    except Exception:
        return None
    if not row:
        return None
    return _permission_result(_hydrate_permission_detail(row))


def _find_permission_live(
    name: str,
    *,
    dosage_hint: str | float | None = None,
) -> dict[str, Any] | None:
    try:
        row = lookup_permission_by_ocr_name(
            name,
            dosage_hint=dosage_hint,
            allow_similar=False,
        )
    except Exception:
        return None
    return _permission_result(_hydrate_permission_detail(row))


def _hydrate_permission_detail(row: dict[str, Any] | None) -> dict[str, Any] | None:
    """목록만 있고 효능이 비면 허가 상세 API를 한 번 채운다."""
    if not row:
        return None
    if str(row.get("efficacy_text") or "").strip():
        return row
    item_seq = str(row.get("item_seq") or "").strip()
    item_name = str(row.get("item_name") or "").strip()
    if not item_seq or not item_name:
        return row
    try:
        if not ensure_detail_for_product(item_seq, item_name):
            return row
        return find_permission_product(item_name) or row
    except Exception:
        return row


def refresh_app_medicines_from_permission() -> int:
    """앱 medicines 테이블에 허가 API 효능·용법·주의사항을 채운다. 코드는 유지."""
    from app.database import get_connection

    conn = get_connection()
    updated = 0
    try:
        rows = conn.execute(
            """
            SELECT id, medicine_code, product_name FROM medicines
            WHERE trim(coalesce(product_name, '')) != ''
            """
        ).fetchall()
        for row in rows:
            name = str(row["product_name"] or "").strip()
            try:
                official = _retrieve_for_app_medicine(name)
            except Exception:
                continue
            med = (official or {}).get("medicine") or {}
            if str(med.get("medicine_code") or "").strip() != str(row["medicine_code"]):
                continue
            efficacy = str(med.get("efficacy") or "").strip()
            if not efficacy:
                continue
            from app.services.pharmacist.ingredient import clean_ingredient_text

            ingredient = clean_ingredient_text(med.get("ingredient"))
            if ingredient == str(med.get("product_name") or name).strip():
                ingredient = ""
            conn.execute(
                """
                UPDATE medicines SET
                    efficacy = ?,
                    ingredient = COALESCE(NULLIF(?, ''), ingredient),
                    usage = COALESCE(NULLIF(?, ''), usage),
                    precautions = COALESCE(NULLIF(?, ''), precautions),
                    manufacturer = COALESCE(NULLIF(?, ''), manufacturer),
                    image_url = COALESCE(NULLIF(?, ''), image_url),
                    updated_at = CURRENT_TIMESTAMP
                WHERE id = ?
                """,
                (
                    efficacy,
                    ingredient,
                    str(med.get("usage") or "").strip(),
                    str(med.get("cautions") or med.get("precautions") or "").strip(),
                    str(med.get("manufacturer") or "").strip(),
                    str(med.get("image_url") or "").strip(),
                    row["id"],
                ),
            )
            updated += 1
            saved = conn.execute(
                "SELECT * FROM medicines WHERE id = ?", (row["id"],)
            ).fetchone()
            if saved:
                from app.services.pharmacist.easy_category import sync_medicine_guidance
                from app.services.medicine_detail_service import ensure_medicine_detail

                sync_medicine_guidance(conn, dict(saved))
                ensure_medicine_detail(conn, str(saved["medicine_code"]))
            # Release the write lock before the next medicine's potentially
            # slow official lookup. Startup initialization already backfills
            # unchanged medicines; this worker only needs to persist this row.
            conn.commit()
    finally:
        conn.close()
    return updated


def start_background_medicine_detail_refresh() -> bool:
    """Refresh missing official details without delaying app/server startup."""
    global _detail_refresh_thread
    with _detail_refresh_lock:
        if _detail_refresh_thread and _detail_refresh_thread.is_alive():
            return False

        def _run() -> None:
            try:
                refresh_app_medicines_from_permission()
            except Exception:
                # Each medicine keeps its local PENDING/OFFICIAL_ONLY profile and
                # can be retried on the next server start.
                return

        _detail_refresh_thread = threading.Thread(
            target=_run,
            name="medicine-detail-refresh",
            daemon=True,
        )
        _detail_refresh_thread.start()
        return True


def upsert_official_app_medicine(official: dict[str, Any]) -> str | None:
    """허가 조회 결과를 앱 medicines에 넣는다. 사용자 복용 등록은 하지 않는다."""
    from app.database import get_connection
    from app.services.pharmacist.easy_category import (
        derive_easy_category_from_medicine,
        sync_medicine_guidance,
    )
    from app.services.pharmacist.ingredient import clean_ingredient_text

    med = (official or {}).get("medicine") or {}
    code = str(med.get("medicine_code") or "").strip()
    name = str(med.get("product_name") or med.get("medicine_name") or "").strip()
    if not code or not name:
        return None
    ingredient = clean_ingredient_text(med.get("ingredient"))
    if ingredient == name:
        ingredient = ""
    precautions = med.get("precautions") or med.get("cautions") or ""
    easy_category = derive_easy_category_from_medicine({**med, "product_name": name})
    conn = get_connection()
    try:
        conn.execute(
            """
            INSERT INTO medicines (
                medicine_code, product_name, ingredient, manufacturer,
                efficacy, usage, precautions, image_url, easy_category
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(medicine_code) DO UPDATE SET
                product_name = excluded.product_name,
                ingredient = CASE
                    WHEN excluded.ingredient IS NOT NULL
                         AND trim(excluded.ingredient) != ''
                    THEN excluded.ingredient
                    ELSE medicines.ingredient
                END,
                manufacturer = COALESCE(NULLIF(trim(excluded.manufacturer), ''), medicines.manufacturer),
                efficacy = COALESCE(NULLIF(trim(excluded.efficacy), ''), medicines.efficacy),
                usage = COALESCE(NULLIF(trim(excluded.usage), ''), medicines.usage),
                precautions = COALESCE(NULLIF(trim(excluded.precautions), ''), medicines.precautions),
                image_url = COALESCE(NULLIF(trim(excluded.image_url), ''), medicines.image_url),
                easy_category = COALESCE(
                    NULLIF(trim(medicines.easy_category), ''),
                    excluded.easy_category
                ),
                updated_at = CURRENT_TIMESTAMP
            """,
            (
                code,
                name,
                ingredient,
                med.get("manufacturer"),
                med.get("efficacy"),
                med.get("usage"),
                precautions if isinstance(precautions, str) else str(precautions or ""),
                med.get("image_url"),
                easy_category,
            ),
        )
        saved = conn.execute(
            "SELECT * FROM medicines WHERE medicine_code = ?", (code,)
        ).fetchone()
        if saved:
            sync_medicine_guidance(conn, dict(saved))
            from app.services.medicine_detail_service import ensure_medicine_detail

            ensure_medicine_detail(conn, code)
        conn.commit()
    finally:
        conn.close()
    return code


def _retrieve_for_app_medicine(name: str) -> dict[str, Any] | None:
    """이미 등록된 약 행용. OCR보다 목록 검색을 한 단계 더 한다."""
    official = retrieve_official(name)
    if str((official or {}).get("medicine", {}).get("efficacy") or "").strip():
        return official
    row = _lookup_list_for_app_refresh(name)
    if not row:
        return official
    return _permission_result(_hydrate_permission_detail(row))


def _refresh_query_variants(name: str) -> list[str]:
    variants: list[str] = []

    def _add(value: str) -> None:
        text = (value or "").strip()
        if text and text not in variants:
            variants.append(text)

    _add(name)
    salt = re.sub(r"정(\d+(?:\.\d+)?밀리그램)$", r"염산염정\1", name)
    _add(salt)
    return variants


def _lookup_list_for_app_refresh(name: str) -> dict[str, Any] | None:
    """제품명이 일반명이어서 공식 1:1 매칭이 안 될 때, 목록이 가리키는 허가 제품을 쓴다."""
    from app.services.mfds_drug_permission.client import (
        extract_items,
        fetch_permission_list_page,
    )
    from app.services.mfds_drug_permission.db import (
        get_permission_connection,
        upsert_list_item,
    )
    from app.services.mfds_drug_permission.sync import initialize_permission_db

    initialize_permission_db()
    for variant in _refresh_query_variants(name):
        try:
            payload = fetch_permission_list_page(
                page_no=1,
                num_of_rows=15,
                item_name=variant,
                timeout=15,
            )
        except Exception:
            continue
        items = extract_items(payload)
        if not items:
            continue
        chosen = items[0]
        conn = get_permission_connection()
        try:
            upsert_list_item(conn, chosen)
            conn.commit()
        finally:
            conn.close()
        found = find_permission_product(str(chosen.get("ITEM_NAME") or ""))
        if found:
            return found
    return None


def search_official_medicine_candidates(query: str, limit: int = 8) -> list[dict[str, Any]]:
    """Local permission-name search for hand entry. Official code only."""
    from app.services.pharmacist.easy_category import display_product_name
    from app.services.mfds_drug_permission.db import search_permission_names

    names = search_permission_names(query, limit=limit)
    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    for name in names:
        official = retrieve_official(name)
        med = (official or {}).get("medicine") or {}
        code = str(med.get("medicine_code") or "").strip()
        if not code or code in seen:
            continue
        seen.add(code)
        product = display_product_name(med.get("product_name") or name) or name
        items.append(
            {
                "medicine_code": code,
                "display_name": product,
                "product_name": product,
                "official_product_name": med.get("product_name") or product,
                "ingredient_name": med.get("ingredient") or "",
                "ingredient": med.get("ingredient") or "",
            }
        )
    return items


def _permission_result(row: dict[str, Any] | None) -> dict[str, Any] | None:
    if not row:
        return None
    medicine = product_to_medicine(row)
    source_text = _local_text(medicine)
    if not source_text.strip() and medicine.get("product_name"):
        source_text = f"product_name: {medicine['product_name']}"
    if not source_text.strip():
        return None
    return {
        "source": "식약처 의약품 제품 허가정보",
        "medicine": medicine,
        "source_text": source_text,
    }


def _local_text(value: dict[str, Any]) -> str:
    fields = (
        "product_name", "ingredient", "efficacy", "usage", "precautions",
        "cautions", "interaction", "side_effects", "storage",
    )
    return "\n".join(
        f"{field}: {value[field]}"
        for field in fields
        if value.get(field)
    )
