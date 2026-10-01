import json
import logging
from typing import Any

from fastapi import HTTPException

from app.core.config import GEMINI_MODEL
from app.database import get_connection
from app.services.mfds_drug_permission.db import (
    find_permission_product,
    product_to_medicine,
)
from app.services.mfds_drug_permission.sync import (
    ensure_detail_for_product,
    lookup_permission_by_ocr_name,
)
from app.services.pharmacist.easy_category import derive_easy_category_from_medicine
from app.services.pharmacist.generate import generate_card_from_source
from app.services.medicine_display import split_ingredients
from app.services.medicine_detail_service import (
    get_medicine_detail_profile,
    ingredient_entries,
    official_source_hash,
)
from app.services.medicine_detail_providers import find_reviewed_ingredient_explanations


logger = logging.getLogger(__name__)
CACHE_MAX_AGE = "-1 day"
MISSING_OFFICIAL_TEXT = "공식 정보에 명시되어 있지 않습니다."


def _ingredient_highlight(cursor, medicine: dict[str, Any], explanation: str) -> str:
    if not explanation:
        return ""
    entries = ingredient_entries(medicine.get("ingredient"))
    if len(entries) != 1:
        return ""
    reviewed = find_reviewed_ingredient_explanations(cursor, entries)
    for entry in entries:
        row = reviewed.get(entry["key"], {})
        for field in ("use_help", "role_explanation"):
            candidate = row.get(field)
            if (
                isinstance(candidate, str)
                and candidate.strip()
                and candidate.strip() != explanation.strip()
                and candidate.strip() in explanation
            ):
                return candidate.strip()
    return ""


def _treatment_use_items(
    summary: str, uses: list[str], all_uses: list[str]
) -> list[dict[str, str]]:
    """Use explicit source headings only, not inferred indication categories.

    Prefer the full list over potentially summarized representative sentences;
    use representatives, then summary, only when the preceding source is absent.
    Ambiguous/unstructured content keeps the existing display fallback.
    """
    source: list[str] = []
    for item in all_uses or uses or ([summary] if summary else []):
        if not isinstance(item, str) or not item.strip() or len(item) > 180:
            return []
        if item not in source:
            source.append(item)
    if not source or len(source) > 3:
        return []
    # Do not hide a separate summary condition by replacing its existing card.
    if summary and not any(summary.strip() in item for item in source):
        return []
    result: list[dict[str, str]] = []
    for item in source:
        separator = '：' if '：' in item else ':'
        title, found, description = item.partition(separator)
        title, description = title.strip(), description.strip()
        if (
            not found or not title or not description or len(title) > 40
            or '\n' in title or title.isdecimal()
            or title in {'성인', '소아', '고령자', '주의', '주의사항', '용법', '용량'}
            or ''.join(title.split()).rstrip('.!?。')
            == ''.join(description.split()).rstrip('.!?。')
        ):
            return []
        result.append({"title": title, "description": description})
    return result


def get_drug_explanation(
    medicine_code: str,
    *,
    force_refresh: bool = False,
) -> dict[str, Any]:
    """상세 화면용 읽기 전용 응답. 화면 조회 중 생성·외부 호출을 하지 않는다."""
    del force_refresh
    conn = get_connection()
    try:
        cursor = conn.cursor()
        medicine = _get_medicine(cursor, medicine_code)
        if not medicine:
            raise HTTPException(status_code=404, detail="의약품이 없습니다.")
        return reviewed_detail_payload(cursor, medicine)
    except HTTPException:
        raise
    except Exception as error:
        conn.rollback()
        logger.warning(
            "Drug explanation pipeline failed for %s: %s",
            medicine_code,
            error,
            exc_info=True,
        )
        raise HTTPException(
            status_code=502,
            detail="검토된 약 설명을 불러오지 못했습니다.",
        ) from error
    finally:
        conn.close()


def reviewed_detail_payload(cursor, medicine: dict[str, Any]) -> dict[str, Any]:
    """공통 상세 프로필을 사용자용으로 구조화한다.

    검토된 쉬운 설명은 READY, 공식 원문만 정리된 내용은 OFFICIAL_ONLY로
    구분한다. 프로필이 아직 없을 때도 화면 조회 중 생성하거나 외부 호출하지
    않고 PENDING 기본 응답을 반환한다.
    """
    code = str(medicine.get("medicine_code") or "").strip()
    profile = get_medicine_detail_profile(cursor, code)
    # An unbound legacy card must not bypass official snapshot validation.
    card = None
    if profile and profile.get("source_hash") != official_source_hash(medicine):
        profile = {**profile, "status": "OUTDATED", "review_status": "UNREVIEWED"}
    status = str((profile or {}).get("status") or ("READY" if card else "PENDING"))
    if status not in {
        "READY",
        "OFFICIAL_ONLY",
        "NEEDS_REVIEW",
        "PENDING",
        "FAILED",
        "OUTDATED",
    }:
        status = "PENDING"
    reviewed = str((profile or {}).get("review_status") or "").upper() == "REVIEWED"
    if card:
        reviewed = True
    stale = status == "OUTDATED"
    ingredient_names = split_ingredients(medicine.get("ingredient"))
    approved_uses = (
        list(profile.get("approved_uses") or [])
        if profile
        else (_json_list(card.get("approved_uses")) if card else [])
    )
    key_cautions = (
        list(profile.get("key_cautions") or [])
        if profile
        else (_json_list(card.get("cautions")) if card else [])
    )[:3]
    side_effects = (
        list(profile.get("possible_side_effects") or [])
        if profile
        else (_json_list(card.get("side_effects")) if card else [])
    )
    ask_doctor_when = (
        list(profile.get("ask_doctor_when") or [])
        if profile
        else (_json_list(card.get("ask_doctor_when")) if card else [])
    )[:3]
    short_explanation = ""
    if str(medicine.get("explanation_review_status") or "").upper() == "REVIEWED":
        short_explanation = str(medicine.get("short_explanation") or "").strip()
    if card and str(card.get("summary") or "").strip() not in {
        "",
        MISSING_OFFICIAL_TEXT,
    }:
        short_explanation = str(card.get("summary") or "").strip()
    official_usage = str(
        (profile or {}).get("official_usage")
        or (card.get("how_to_take") if card else None)
        or medicine.get("usage")
        or ""
    ).strip()
    ingredient_explanation = str(
        (profile or {}).get("ingredient_explanation")
        or (card.get("ingredient_explanation") if card else "")
        or ""
    ).strip()
    approved_use_summary = str(
        (profile or {}).get("approved_use_summary")
        or (card.get("approved_use_summary") if card else "")
        or ""
    ).strip()
    all_approved_uses = list((profile or {}).get("all_approved_uses") or approved_uses)
    if stale:
        # A cached card/summary must not reintroduce an outdated explanation.
        short_explanation = ""
        ingredient_explanation = ""
        approved_use_summary = ""
        approved_uses = []
        all_approved_uses = []
        reviewed = False
        official_usage = str(medicine.get("usage") or "").strip()
        key_cautions = []
        side_effects = []
        ask_doctor_when = []
    ingredient_highlight = _ingredient_highlight(cursor, medicine, ingredient_explanation)
    treatment_uses = _treatment_use_items(
        approved_use_summary, approved_uses, all_approved_uses
    )
    return {
        "medicine": {
            "medicine_code": code,
            "display_name": medicine.get("product_name") or "약",
            "manufacturer": medicine.get("manufacturer"),
            "ingredients": [
                {
                    "name": name,
                    "strength": medicine.get("ingredient_strength")
                    if index == 0
                    else None,
                }
                for index, name in enumerate(ingredient_names)
            ],
        },
        "explanation": {
            "content_available": bool(
                ingredient_explanation
                or approved_use_summary
                or approved_uses
                or all_approved_uses
            ),
            "short_explanation": short_explanation,
            "ingredient_explanation": ingredient_explanation,
            "ingredient_highlight": ingredient_highlight,
            "approved_use_summary": approved_use_summary,
            "approved_uses": approved_uses,
            "all_approved_uses": all_approved_uses,
            "treatment_uses": treatment_uses,
            "review_status": "REVIEWED" if reviewed else "UNAVAILABLE",
            "status": status,
            "quality_flags": list((profile or {}).get("quality_flags") or []),
        },
        "official_usage": {
            "available": bool(official_usage),
            "text": official_usage,
            "notice": "제품 설명서의 일반적인 사용법이에요. 실제로는 처방전과 의료진의 안내대로 복용하세요.",
        },
        "safety": {
            "key_cautions": key_cautions,
            "possible_side_effects": side_effects,
            "ask_doctor_when": ask_doctor_when,
        },
        "source": {
            "name": str(
                (profile or {}).get("source_name")
                or (card.get("source") if card else None)
                or "식약처 의약품 허가정보"
            ),
            "source_verified": bool((profile or {}).get("source_verified"))
            if profile
            else (bool(card.get("source_verified")) if card else False),
            "content_review_status": "REVIEWED" if reviewed else "UNAVAILABLE",
            "content_generated_by": str(
                (profile or {}).get("generated_by")
                or (card.get("content_generated_by") if card else None)
                or ""
            ),
            "served_from": "local-cache",
            "source_url": str(
                (profile or {}).get("source_url")
                or (card.get("source_url") if card else None)
                or ""
            ),
            "content_version": int(
                (profile or {}).get("content_version")
                or (card.get("content_version") if card else 0)
                or 0
            ),
        },
    }


def _fetch_mfds_info(
    medicine_code: str,
    medicine_name: str | None,
) -> dict[str, Any] | None:
    """식약처 의약품 제품 허가정보만 사용. 로컬 DB → 없으면 실시간 허가 API."""
    row = None
    if medicine_name:
        try:
            row = find_permission_product(medicine_name)
        except Exception:
            row = None
    if not row and medicine_code:
        try:
            row = find_permission_product(medicine_code)
        except Exception:
            row = None
    if not row and medicine_name:
        try:
            row = lookup_permission_by_ocr_name(medicine_name)
        except Exception:
            row = None
    if not row:
        return None

    # 상세(효능·복용법·주의사항)가 없으면 허가 상세 API로 한 번 채운다.
    if not (row.get("efficacy_text") or row.get("usage_text") or row.get("caution_text")):
        try:
            ensure_detail_for_product(
                str(row.get("item_seq") or ""),
                str(row.get("item_name") or ""),
            )
            row = find_permission_product(str(row.get("item_name") or "")) or row
        except Exception:
            pass
    return product_to_medicine(row)


def _get_medicine(cursor, medicine_code: str) -> dict[str, Any] | None:
    row = cursor.execute(
        "SELECT * FROM medicines WHERE medicine_code = ?",
        (medicine_code,),
    ).fetchone()
    return dict(row) if row else None


def _get_latest_card(
    cursor,
    medicine_code: str,
    *,
    fresh_only: bool = False,
) -> dict[str, Any] | None:
    freshness = (
        "AND datetime(created_at) >= datetime('now', ?)" if fresh_only else ""
    )
    params: tuple[Any, ...] = (
        (medicine_code, CACHE_MAX_AGE)
        if fresh_only
        else (medicine_code,)
    )
    row = cursor.execute(
        f"""
        SELECT * FROM ai_explanation_cards
        WHERE medicine_code = ?
        {freshness}
        ORDER BY created_at DESC, id DESC
        LIMIT 1
        """,
        params,
    ).fetchone()
    return dict(row) if row else None


def _get_latest_reviewed_card(cursor, medicine_code: str) -> dict[str, Any] | None:
    row = cursor.execute(
        """
        SELECT * FROM ai_explanation_cards
        WHERE medicine_code = ? AND review_status = 'REVIEWED'
        ORDER BY content_version DESC, reviewed_at DESC, id DESC
        LIMIT 1
        """,
        (medicine_code,),
    ).fetchone()
    return dict(row) if row else None


def _save_official_document(
    cursor,
    medicine_code: str,
    official_info: dict[str, Any],
) -> int:
    content = json.dumps(official_info, ensure_ascii=False)
    existing = cursor.execute(
        """
        SELECT id FROM medicine_documents
        WHERE medicine_code = ? AND document_type = 'MFDS_PERMISSION'
          AND content = ?
        ORDER BY id DESC LIMIT 1
        """,
        (medicine_code, content),
    ).fetchone()
    if existing:
        return existing["id"]

    cursor.execute(
        """
        INSERT INTO medicine_documents (
            medicine_code, document_type, title, content, source_url
        ) VALUES (?, 'MFDS_PERMISSION', ?, ?, ?)
        """,
        (
            medicine_code,
            official_info.get("product_name") or medicine_code,
            content,
            "https://nedrug.mfds.go.kr",
        ),
    )
    return cursor.lastrowid


def _upsert_medicine(
    cursor,
    medicine_code: str,
    local: dict[str, Any] | None,
    official: dict[str, Any],
) -> None:
    local = local or {}
    merged = {
        **local,
        **{key: value for key, value in official.items() if value},
        "product_name": official.get("product_name")
        or local.get("product_name")
        or medicine_code,
    }
    easy_category = local.get("easy_category") or derive_easy_category_from_medicine(
        merged
    )
    cursor.execute(
        """
        INSERT INTO medicines (
            medicine_code, product_name, ingredient, manufacturer,
            efficacy, usage, precautions, image_url, easy_category
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(medicine_code) DO UPDATE SET
            product_name = excluded.product_name,
            ingredient = excluded.ingredient,
            manufacturer = excluded.manufacturer,
            efficacy = excluded.efficacy,
            usage = excluded.usage,
            precautions = excluded.precautions,
            image_url = excluded.image_url,
            easy_category = COALESCE(
                NULLIF(trim(medicines.easy_category), ''),
                excluded.easy_category
            ),
            updated_at = CURRENT_TIMESTAMP
        """,
        (
            medicine_code,
            merged["product_name"],
            official.get("ingredient")
            or local.get("ingredient")
            or None,
            official.get("manufacturer") or local.get("manufacturer"),
            official.get("efficacy") or local.get("efficacy"),
            official.get("usage") or local.get("usage"),
            official.get("cautions") or local.get("precautions"),
            official.get("image_url") or local.get("image_url"),
            easy_category,
        ),
    )


def _save_card(
    cursor,
    medicine_code: str,
    card: dict[str, Any],
    document_ids: list[int],
) -> dict[str, Any]:
    cautions = _ensure_consultation(_string_list(card.get("cautions")))
    ask_doctor_when = _ensure_consultation(
        _string_list(card.get("ask_doctor_when"))
    )
    side_effects = _string_list(card.get("possible_side_effects"))
    cursor.execute(
        """
        INSERT INTO ai_explanation_cards (
            medicine_code, summary, what_it_does, how_to_take,
            warnings, cautions, side_effects, storage, ask_doctor_when,
            source_based, official_raw_summary, source_document_ids,
            model_name, generated_by, source, is_verified
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            medicine_code,
            card.get("easy_summary") or MISSING_OFFICIAL_TEXT,
            card.get("what_it_does") or MISSING_OFFICIAL_TEXT,
            card.get("how_to_take") or MISSING_OFFICIAL_TEXT,
            json.dumps(cautions, ensure_ascii=False),
            json.dumps(cautions, ensure_ascii=False),
            json.dumps(side_effects, ensure_ascii=False),
            card.get("storage") or MISSING_OFFICIAL_TEXT,
            json.dumps(ask_doctor_when, ensure_ascii=False),
            int(bool(card.get("source_based"))),
            card.get("official_raw_summary") or "",
            json.dumps(document_ids),
            card.get("model_name") or "mock",
            card.get("generated_by") or "mock",
            card.get("source") or "local",
            int(bool(card.get("is_verified"))),
        ),
    )
    return dict(
        cursor.execute(
            "SELECT * FROM ai_explanation_cards WHERE id = ?",
            (cursor.lastrowid,),
        ).fetchone()
    )


def _official_fallback(info: dict[str, Any]) -> dict[str, Any]:
    cautions = _string_list(info.get("cautions"))
    if interaction := info.get("interaction"):
        cautions.append(f"상호작용: {interaction}")
    return {
        "easy_summary": (
            f"{info.get('product_name') or '이 약'}의 식약처 허가 공식 정보를 "
            "쉬운 항목으로 정리했습니다."
        ),
        "what_it_does": info.get("efficacy") or MISSING_OFFICIAL_TEXT,
        "how_to_take": info.get("usage") or MISSING_OFFICIAL_TEXT,
        "cautions": cautions or [MISSING_OFFICIAL_TEXT],
        "possible_side_effects": _string_list(info.get("side_effects"))
        or [MISSING_OFFICIAL_TEXT],
        "storage": info.get("storage") or MISSING_OFFICIAL_TEXT,
        "ask_doctor_when": [
            "복용 중 이상 증상이 있거나 복용 방법이 걱정되면 의사/약사와 상담하세요."
        ],
        "source_based": True,
    }


def _local_fallback(medicine: dict[str, Any]) -> dict[str, Any]:
    product_name = medicine.get("product_name") or "이 약"
    ingredient = medicine.get("ingredient") or "확인되지 않은"
    return {
        "easy_summary": f"{product_name}은(는) {ingredient} 성분의 약입니다.",
        "what_it_does": medicine.get("efficacy") or "효능 정보는 확인 중입니다.",
        "how_to_take": medicine.get("usage") or "처방 지시에 따라 복용하세요.",
        "cautions": _string_list(medicine.get("precautions"))
        or ["이상 반응이 있으면 복용을 중단하고 상담하세요."],
        "possible_side_effects": ["공식 부작용 정보가 없습니다."],
        "storage": "공식 보관 정보가 없습니다.",
        "ask_doctor_when": [
            "궁금하거나 이상 반응이 있으면 의사/약사와 상담하세요."
        ],
        "source_based": False,
    }


def _official_raw_summary(info: dict[str, Any]) -> str:
    labels = (
        ("제품명", "product_name"),
        ("성분명", "ingredient"),
        ("효능/효과", "efficacy"),
        ("복용법", "usage"),
        ("주의사항", "cautions"),
        ("상호작용", "interaction"),
        ("부작용", "side_effects"),
        ("보관법", "storage"),
    )
    return "\n".join(
        f"{label}: {info.get(key) or MISSING_OFFICIAL_TEXT}"
        for label, key in labels
    )


def _response(
    medicine: dict[str, Any],
    card: dict[str, Any],
    *,
    generated_by: str | None = None,
) -> dict[str, Any]:
    cautions = _json_list(card.get("cautions") or card.get("warnings"))
    side_effects = _json_list(card.get("side_effects"))
    ask_doctor_when = _json_list(card.get("ask_doctor_when"))
    response = {
        "medicine_code": medicine.get("medicine_code"),
        "drug_name": medicine.get("product_name"),
        "ingredient": medicine.get("ingredient"),
        "easy_summary": card.get("summary") or MISSING_OFFICIAL_TEXT,
        "what_it_does": card.get("what_it_does") or MISSING_OFFICIAL_TEXT,
        "how_to_take": card.get("how_to_take") or MISSING_OFFICIAL_TEXT,
        "cautions": cautions,
        "possible_side_effects": side_effects,
        "storage": card.get("storage") or MISSING_OFFICIAL_TEXT,
        "ask_doctor_when": ask_doctor_when,
        "generated_by": generated_by
        or card.get("generated_by")
        or card.get("model_name")
        or "mock",
        "source": card.get("source") or "local",
        "is_verified": bool(card.get("is_verified")),
        "source_based": bool(card.get("source_based")),
        "official_raw_summary": card.get("official_raw_summary") or "",
    }
    response["medicine"] = medicine
    response["explanation"] = {
        **response,
        "summary": response["easy_summary"],
        "side_effects": response["possible_side_effects"],
        "warnings": response["cautions"],
    }
    return response


def _safe_existing_or_fallback(conn, medicine_code: str) -> dict[str, Any]:
    cursor = conn.cursor()
    medicine = _get_medicine(cursor, medicine_code)
    if not medicine:
        raise HTTPException(status_code=404, detail="의약품이 없습니다.")
    cached = _get_latest_card(cursor, medicine_code)
    if cached:
        return _response(medicine, cached, generated_by="local-cache")
    return _response(
        medicine,
        {
            "summary": _local_fallback(medicine)["easy_summary"],
            "what_it_does": medicine.get("efficacy"),
            "how_to_take": medicine.get("usage"),
            "cautions": json.dumps(
                _local_fallback(medicine)["cautions"], ensure_ascii=False
            ),
            "side_effects": json.dumps(
                _local_fallback(medicine)["possible_side_effects"],
                ensure_ascii=False,
            ),
            "storage": "공식 보관 정보가 없습니다.",
            "ask_doctor_when": json.dumps(
                _local_fallback(medicine)["ask_doctor_when"],
                ensure_ascii=False,
            ),
            "generated_by": "mock",
            "source": "local",
            "is_verified": 0,
            "source_based": 0,
        },
    )


def _ensure_consultation(values: list[str]) -> list[str]:
    if not any("의사/약사와 상담하세요" in value for value in values):
        values.append("궁금하거나 이상 반응이 있으면 의사/약사와 상담하세요.")
    return values


def _string_list(value: Any) -> list[str]:
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    text = str(value or "").strip()
    if not text:
        return []
    return [line.strip(" -•") for line in text.splitlines() if line.strip(" -•")]


def _json_list(value: Any) -> list[str]:
    if isinstance(value, list):
        return _string_list(value)
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
            if isinstance(parsed, list):
                return _string_list(parsed)
        except json.JSONDecodeError:
            pass
    return _string_list(value)
