"""Deterministic medicine-detail preparation shared by DB and OCR medicines.

This module never calls Gemini or an external API. It turns already stored MFDS
fields into a safe OFFICIAL_ONLY profile and overlays reviewed human content when
available. External enrichment can therefore run separately without blocking a
prescription registration or a detail-screen request.
"""

from __future__ import annotations

import hashlib
import json
import re
from typing import Any

from app.services.medicine_display import split_ingredients
from app.services.medicine_detail_providers import (
    clean_ingredient_explanation,
    find_reviewed_ingredient_explanations,
    is_displayable_ingredient_explanation,
)


PROFILE_STATUSES = frozenset(
    {"READY", "OFFICIAL_ONLY", "NEEDS_REVIEW", "PENDING", "FAILED", "OUTDATED"}
)
JOB_STATUSES = frozenset(
    {"PENDING", "FETCHING", "DRAFT", "READY", "FAILED", "OUTDATED"}
)
_STRENGTH = re.compile(
    r"\b\d+(?:\.\d+)?\s*(?:mg|mcg|μg|g|ml|mL|밀리그램|밀리그람|마이크로그램|밀리리터|%)\b",
    re.I,
)
_SPACE = re.compile(r"\s+")
_HTML = re.compile(r"<\s*/?\s*[A-Za-z][^>]*>")
_LEADING_MARK = re.compile(r"^(?:\d+[.)]|[가-하][.)]|[-•·※]+)\s*")
PARSER_VERSION = "4.0"
_BOILERPLATE_PURPOSES = (
    "다음 질환에도 사용할 수 있다",
    "다음 질환에 사용할 수 있다",
    "다음의 질환 및 증상",
    "주효능 효과",
    "효능 효과",
)
_PURPOSE_GROUPS: tuple[tuple[re.Pattern[str], str], ...] = (
    (
        re.compile(r"발열|해열|감기.*(?:열|통증)"),
        "열을 내리고 감기로 인한 통증을 줄이는 데 사용해요.",
    ),
    (
        re.compile(r"두통|치통|월경곤란|생리통|요통|근육통|신경통|수술\s*후\s*통증"),
        "두통·치통·생리통 등 여러 통증을 줄이는 데 사용해요.",
    ),
    (
        re.compile(r"관절염|류마티|통풍|염좌|좌상|건염|건초염|활액낭염|소염"),
        "관절이나 근육의 염증과 통증을 줄이는 데 사용해요.",
    ),
    (
        re.compile(r"가려움|두드러기|알레르기|알러지"),
        "알레르기로 인한 가려움 같은 증상을 줄이는 데 사용해요.",
    ),
    (
        re.compile(r"위산|속쓰림|역류|위궤양|십이지장궤양"),
        "위산과 관련된 속쓰림이나 위 불편감을 줄이는 데 사용해요.",
    ),
    (
        re.compile(r"부정맥|심실세동|심방세동|빈맥"),
        "불규칙하거나 지나치게 빠른 심장 박동을 조절하는 데 사용해요.",
    ),
    (
        re.compile(r"고혈압|혈압"),
        "높은 혈압을 조절하는 데 사용해요.",
    ),
    (
        re.compile(r"당뇨|혈당"),
        "혈당을 조절하는 데 사용해요.",
    ),
)
def normalize_ingredient_key(value: str | None) -> str:
    """Make a stable reuse key without changing the official display value."""
    text = _HTML.sub(" ", str(value or ""))
    text = _STRENGTH.sub(" ", text)
    text = re.sub(r"\([^)]*(?:함량|역가)[^)]*\)", " ", text)
    text = _SPACE.sub(" ", text).strip(" ,;|/·").casefold()
    return text


def ingredient_entries(raw: str | None) -> list[dict[str, str]]:
    entries: list[dict[str, str]] = []
    seen: set[str] = set()
    for name in split_ingredients(raw):
        key = normalize_ingredient_key(name)
        if not key or key in seen:
            continue
        seen.add(key)
        entries.append({"key": key, "name": name.strip()})
    return entries


def enqueue_medicine_detail(cursor, medicine_code: str) -> None:
    """Idempotently enqueue one official medicine for local/background preparation."""
    code = str(medicine_code or "").strip()
    if not code or code.upper().startswith("OCR-"):
        return
    cursor.execute(
        """
        INSERT INTO medicine_detail_jobs (medicine_code, status)
        VALUES (?, 'PENDING')
        ON CONFLICT(medicine_code) DO UPDATE SET
            status = CASE
                WHEN medicine_detail_jobs.status IN ('FETCHING', 'DRAFT')
                THEN medicine_detail_jobs.status
                ELSE 'PENDING'
            END,
            requested_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP,
            last_error = NULL
        """,
        (code,),
    )


def ensure_medicine_detail(cursor, medicine_code: str) -> dict[str, Any] | None:
    """Prepare one profile using local official data and reviewed content only."""
    code = str(medicine_code or "").strip()
    medicine_row = cursor.execute(
        "SELECT * FROM medicines WHERE medicine_code = ? AND medicine_code NOT LIKE 'OCR-%'",
        (code,),
    ).fetchone()
    if not medicine_row:
        return None
    medicine = dict(medicine_row)
    medicine = _hydrate_from_local_permission(cursor, medicine)
    enqueue_medicine_detail(cursor, code)
    cursor.execute(
        """
        UPDATE medicine_detail_jobs
        SET status='FETCHING', attempts=attempts+1, started_at=CURRENT_TIMESTAMP,
            updated_at=CURRENT_TIMESTAMP
        WHERE medicine_code=?
        """,
        (code,),
    )

    try:
        existing = cursor.execute(
            "SELECT source_hash, content_version FROM medicine_detail_profiles WHERE medicine_code=?",
            (code,),
        ).fetchone()
        # A reviewed card without a matching official snapshot has no proven
        # connection to today's product. Never promote it merely by rebuilding.
        source_hash = official_source_hash(medicine)
        if not existing or existing["source_hash"] != source_hash:
            cursor.execute(
                "UPDATE ai_explanation_cards SET review_status='OUTDATED' "
                "WHERE medicine_code=? AND review_status='REVIEWED'", (code,)
            )
            cursor.execute(
                "UPDATE medicines SET explanation_review_status='UNREVIEWED' "
                "WHERE medicine_code=?", (code,)
            )
        profile = _build_profile(cursor, medicine)
        if (
            existing
            and str(existing["source_hash"] or "")
            and existing["source_hash"] != profile["source_hash"]
        ):
            cursor.execute(
                "UPDATE medicine_detail_profiles SET status='OUTDATED', updated_at=CURRENT_TIMESTAMP WHERE medicine_code=?",
                (code,),
            )
            cursor.execute(
                "UPDATE medicine_detail_jobs SET status='OUTDATED', updated_at=CURRENT_TIMESTAMP WHERE medicine_code=?",
                (code,),
            )
        if existing and existing["source_hash"] == profile["source_hash"]:
            version = int(existing["content_version"] or 1)
        else:
            version = int(existing["content_version"] or 0) + 1 if existing else 1

        cursor.execute(
            """
            INSERT INTO medicine_detail_profiles (
                medicine_code, status, ingredient_keys, ingredient_explanation,
                approved_use_summary, approved_uses, all_approved_uses, official_usage,
                key_cautions, possible_side_effects, ask_doctor_when,
                source_name, source_url, source_verified, review_status,
                generated_by, source_hash, quality_flags, parser_version,
                content_version, prepared_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(medicine_code) DO UPDATE SET
                status=excluded.status,
                ingredient_keys=excluded.ingredient_keys,
                ingredient_explanation=excluded.ingredient_explanation,
                approved_use_summary=excluded.approved_use_summary,
                approved_uses=excluded.approved_uses,
                all_approved_uses=excluded.all_approved_uses,
                official_usage=excluded.official_usage,
                key_cautions=excluded.key_cautions,
                possible_side_effects=excluded.possible_side_effects,
                ask_doctor_when=excluded.ask_doctor_when,
                source_name=excluded.source_name,
                source_url=excluded.source_url,
                source_verified=excluded.source_verified,
                review_status=excluded.review_status,
                generated_by=excluded.generated_by,
                source_hash=excluded.source_hash,
                quality_flags=excluded.quality_flags,
                parser_version=excluded.parser_version,
                content_version=excluded.content_version,
                prepared_at=CURRENT_TIMESTAMP,
                updated_at=CURRENT_TIMESTAMP
            """,
            (
                code,
                profile["status"],
                _dump(profile["ingredient_keys"]),
                profile["ingredient_explanation"],
                profile["approved_use_summary"],
                _dump(profile["approved_uses"]),
                _dump(profile["all_approved_uses"]),
                profile["official_usage"],
                _dump(profile["key_cautions"]),
                _dump(profile["possible_side_effects"]),
                _dump(profile["ask_doctor_when"]),
                profile["source_name"],
                profile["source_url"],
                int(profile["source_verified"]),
                profile["review_status"],
                profile["generated_by"],
                profile["source_hash"],
                _dump(profile["quality_flags"]),
                PARSER_VERSION,
                version,
            ),
        )
        cursor.execute(
            """
            UPDATE medicine_detail_jobs
            SET status=?, source_hash=?, last_error=NULL,
                finished_at=CURRENT_TIMESTAMP, updated_at=CURRENT_TIMESTAMP
            WHERE medicine_code=?
            """,
            (
                "READY"
                if profile["status"] in {"READY", "OFFICIAL_ONLY", "NEEDS_REVIEW"}
                else "PENDING",
                profile["source_hash"],
                code,
            ),
        )
        return get_medicine_detail_profile(cursor, code)
    except Exception as error:
        cursor.execute(
            """
            UPDATE medicine_detail_jobs
            SET status='FAILED', last_error=?, finished_at=CURRENT_TIMESTAMP,
                updated_at=CURRENT_TIMESTAMP
            WHERE medicine_code=?
            """,
            (str(error)[:500], code),
        )
        raise


def prepare_all_medicine_details(cursor) -> dict[str, int]:
    """Backfill every real app medicine without network access."""
    codes = [
        str(row[0])
        for row in cursor.execute(
            """
            SELECT medicine_code FROM medicines
            WHERE medicine_code NOT LIKE 'OCR-%'
            ORDER BY CASE WHEN medicine_code IN (
                SELECT DISTINCT medicine_code FROM user_medicines WHERE is_active=1
            ) THEN 0 ELSE 1 END, medicine_code
            """
        ).fetchall()
    ]
    result = {
        "total": len(codes),
        "ready": 0,
        "official_only": 0,
        "needs_review": 0,
        "pending": 0,
        "failed": 0,
    }
    for code in codes:
        try:
            profile = ensure_medicine_detail(cursor, code)
            status = str((profile or {}).get("status") or "PENDING").lower()
            result[status if status in result else "pending"] += 1
        except Exception:
            result["failed"] += 1
    return result


def get_medicine_detail_profile(cursor, medicine_code: str) -> dict[str, Any] | None:
    row = cursor.execute(
        "SELECT * FROM medicine_detail_profiles WHERE medicine_code=?",
        (medicine_code,),
    ).fetchone()
    if not row:
        return None
    profile = dict(row)
    for key in (
        "ingredient_keys",
        "approved_uses",
        "all_approved_uses",
        "key_cautions",
        "possible_side_effects",
        "ask_doctor_when",
        "quality_flags",
    ):
        profile[key] = _load_list(profile.get(key))
    return profile


def _build_profile(cursor, medicine: dict[str, Any]) -> dict[str, Any]:
    code = str(medicine["medicine_code"])
    ingredients = ingredient_entries(medicine.get("ingredient"))
    reviewed_card_row = cursor.execute(
        """
        SELECT * FROM ai_explanation_cards
        WHERE medicine_code=? AND review_status='REVIEWED'
        ORDER BY content_version DESC, reviewed_at DESC, id DESC LIMIT 1
        """,
        (code,),
    ).fetchone()
    card = dict(reviewed_card_row) if reviewed_card_row else None

    ingredient_explanation = ""
    reviewed_by_key = find_reviewed_ingredient_explanations(cursor, ingredients)
    ingredient_provider_names: set[str] = set()
    for ingredient in ingredients:
        row = reviewed_by_key.get(ingredient["key"])
        if row:
            ingredient_provider_names.add(str(row.get("provider") or ""))
    if ingredients and len(reviewed_by_key) == len(ingredients):
        ingredient_explanation = _compose_reviewed_ingredient_explanation(
            ingredients,
            reviewed_by_key,
        )
    if card and ingredients and is_displayable_ingredient_explanation(card.get("ingredient_explanation")):
        # A product review bound to the current snapshot may supply product copy,
        # but must never be copied into a global ingredient dictionary.
        ingredient_explanation = clean_ingredient_explanation(card["ingredient_explanation"])

    quality_flags: list[str] = []
    if card:
        all_approved_uses = _deduplicate_items(_load_list(card.get("approved_uses")))
        approved_uses = all_approved_uses if len(all_approved_uses) <= 3 else []
        approved_summary = str(card.get("approved_use_summary") or "").strip()
        approved_uses = _without_summary_duplicate(approved_uses, approved_summary)
    else:
        parsed_purposes = _parse_official_purposes(medicine.get("efficacy"))
        approved_uses = parsed_purposes["representative"]
        all_approved_uses = parsed_purposes["all"]
        quality_flags.extend(parsed_purposes["flags"])
        approved_summary = (
            "공식 허가정보에서 확인한 대표 사용 목적이에요."
            if len(approved_uses) > 1
            else (approved_uses[0] if approved_uses else "")
        )
        if len(approved_uses) == 1:
            approved_uses = []

    if ingredients and not ingredient_explanation:
        quality_flags.append("missing_reviewed_ingredient_explanation")

    key_cautions = _load_list(card.get("cautions")) if card else []
    if not key_cautions:
        key_cautions = _official_items(medicine.get("precautions"), limit=3)
    side_effects = _load_list(card.get("side_effects")) if card else []
    side_effects = [item for item in side_effects if _complete_user_text(item)][:4]
    ask_doctor_when = _load_list(card.get("ask_doctor_when")) if card else []
    if not ask_doctor_when and key_cautions:
        ask_doctor_when = ["복용 중 불편한 증상이 생기거나 복용 방법이 걱정될 때 의사나 약사에게 알려주세요."]

    has_official = any(
        str(medicine.get(key) or "").strip()
        for key in ("efficacy", "usage", "precautions", "ingredient")
    )
    # Reviewed ingredient copy is not a review of the entire product/indications.
    fully_reviewed = bool(card)
    if fully_reviewed:
        status = "READY"
    elif quality_flags:
        status = "NEEDS_REVIEW"
    else:
        status = "OFFICIAL_ONLY" if has_official else "PENDING"
    review_status = "REVIEWED" if fully_reviewed else "UNREVIEWED"
    return {
        "status": status,
        "ingredient_keys": [item["key"] for item in ingredients],
        "ingredient_explanation": ingredient_explanation,
        "approved_use_summary": approved_summary,
        "approved_uses": approved_uses,
        "all_approved_uses": all_approved_uses,
        "official_usage": str((card or {}).get("how_to_take") or medicine.get("usage") or "").strip(),
        "key_cautions": key_cautions,
        "possible_side_effects": side_effects,
        "ask_doctor_when": ask_doctor_when,
        "source_name": str(
            (card or {}).get("source")
            or (
                "식약처 의약품 허가정보 · 검토된 성분 설명 사전"
                if ingredient_provider_names
                else "식약처 의약품 허가정보"
            )
        ),
        "source_url": str((card or {}).get("source_url") or "https://nedrug.mfds.go.kr"),
        "source_verified": has_official or bool(card),
        "review_status": review_status,
        "generated_by": str(
            (card or {}).get("content_generated_by")
            or ("ingredient-provider" if ingredient_provider_names else "official-parser")
        ),
        "quality_flags": quality_flags,
        "source_hash": official_source_hash(medicine),
    }


def _hydrate_from_local_permission(cursor, medicine: dict[str, Any]) -> dict[str, Any]:
    """Fill missing official fields from the local MFDS mirror only."""
    try:
        from app.services.mfds_drug_permission.db import (
            find_permission_product_by_item_seq,
            product_to_medicine,
        )

        row = find_permission_product_by_item_seq(str(medicine.get("medicine_code") or ""))
        official = product_to_medicine(row) if row else {}
    except Exception:
        official = {}
    if not official or str(official.get("medicine_code") or "") != str(medicine.get("medicine_code") or ""):
        return medicine

    merged = dict(medicine)
    field_map = {
        "ingredient": "ingredient",
        "manufacturer": "manufacturer",
        "efficacy": "efficacy",
        "usage": "usage",
        "precautions": "precautions",
        "image_url": "image_url",
    }
    updates: dict[str, str] = {}
    for target, source in field_map.items():
        current = str(merged.get(target) or "").strip()
        incoming = str(official.get(source) or "").strip()
        if not current and incoming:
            merged[target] = incoming
            updates[target] = incoming
    if updates:
        assignments = ", ".join(f"{name}=?" for name in updates)
        cursor.execute(
            f"UPDATE medicines SET {assignments}, updated_at=CURRENT_TIMESTAMP WHERE medicine_code=?",
            (*updates.values(), medicine["medicine_code"]),
        )
    return merged


def _store_reviewed_ingredient(
    cursor,
    ingredient: dict[str, str],
    explanation: str,
    *,
    source: str,
    generated_by: str,
) -> None:
    cursor.execute(
        """
        INSERT INTO ingredient_explanations (
            normalized_key, ingredient_name, explanation, review_status,
            source, source_verified, generated_by, reviewed_at
        ) VALUES (?, ?, ?, 'REVIEWED', ?, 1, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(normalized_key) DO UPDATE SET
            ingredient_name=excluded.ingredient_name,
            explanation=CASE
                WHEN ingredient_explanations.review_status='REVIEWED'
                THEN ingredient_explanations.explanation
                ELSE excluded.explanation
            END,
            review_status='REVIEWED', source_verified=1,
            updated_at=CURRENT_TIMESTAMP,
            reviewed_at=COALESCE(ingredient_explanations.reviewed_at, CURRENT_TIMESTAMP)
        """,
        (
            ingredient["key"],
            ingredient["name"],
            explanation,
            source,
            generated_by,
        ),
    )


def _official_items(value: Any, *, limit: int) -> list[str]:
    text = _HTML.sub(" ", str(value or ""))
    text = text.replace("\r", "\n")
    candidates = re.split(r"(?:\n+|(?<=[.!?다요])\s+|\s+[※•])", text)
    result: list[str] = []
    for candidate in candidates:
        item = _LEADING_MARK.sub("", _SPACE.sub(" ", candidate)).strip(" -•·")
        if not _complete_user_text(item) or len(item) > 240 or item in result:
            continue
        result.append(item)
        if len(result) >= limit:
            break
    return result


def _parse_official_purposes(value: Any) -> dict[str, list[str]]:
    """Separate concise representative purposes from the preserved official list."""
    raw = _HTML.sub(" ", str(value or "")).replace("\r", "\n")
    cleaned = re.sub(r"[ \t\f\v]+", " ", raw).strip()
    if not cleaned:
        return {"representative": [], "all": [], "flags": ["missing_purpose"]}

    # Without a structured source, a heading/exception can qualify later lines.
    # Keep the entire document together instead of splitting commas or clauses.
    all_items = [cleaned]
    flags: list[str] = []
    if not all_items:
        flags.append("unparsed_purpose")
    if any(len(item) > 160 for item in all_items):
        flags.append("long_purpose_item")
    if len(all_items) == 1 and len(all_items[0]) > 120:
        flags.append("unparsed_long_text")

    # No keyword-generated indications or partial selection that could drop an
    # age restriction/exception. Long official lists remain in the full list.
    representative = all_items if len(all_items) <= 3 else []
    if not representative and all_items:
        flags.append("no_representative_purpose")
    return {
        "representative": representative[:3],
        "all": all_items,
        "flags": list(dict.fromkeys(flags)),
    }


def _compose_reviewed_ingredient_explanation(
    ingredients: list[dict[str, str]],
    reviewed_by_key: dict[str, dict[str, Any]],
) -> str:
    """Compose only complete, verified copy; never splice approved-use text."""
    rows = [reviewed_by_key[item["key"]] for item in ingredients]
    group_keys = {str(row.get("role_group") or "").strip() for row in rows}
    group_texts = {
        clean_ingredient_explanation(row.get("group_explanation")) for row in rows
    }
    group_keys.discard("")
    group_texts.discard("")
    if (
        len(ingredients) > 1
        and len(group_keys) == 1
        and len(group_texts) == 1
        and all(str(row.get("role_group") or "").strip()
                and clean_ingredient_explanation(row.get("group_explanation"))
                for row in rows)
    ):
        grouped = next(iter(group_texts))
        if is_displayable_ingredient_explanation(grouped):
            return grouped

    explanations: list[str] = []
    for ingredient, row in zip(ingredients, rows):
        text = clean_ingredient_explanation(row.get("explanation"))
        if not is_displayable_ingredient_explanation(text):
            return ""
        explanations.append(text if len(ingredients) == 1 else f"{ingredient['name']}: {text}")
    return "\n".join(explanations)


def _split_top_level_commas(value: str) -> list[str]:
    """Split a permission list without breaking commas inside parentheses."""
    result: list[str] = []
    current: list[str] = []
    depth = 0
    for char in str(value or ""):
        if char in "([（":
            depth += 1
        elif char in ")]）" and depth:
            depth -= 1
        if char in ",，" and depth == 0:
            piece = "".join(current).strip()
            if piece:
                result.append(piece)
            current = []
        else:
            current.append(char)
    piece = "".join(current).strip()
    if piece:
        result.append(piece)
    return result


def _clean_purpose_item(value: str) -> str:
    text = _LEADING_MARK.sub("", _SPACE.sub(" ", str(value or ""))).strip(
        " -•·,.;:："
    )
    for phrase in _BOILERPLATE_PURPOSES:
        if _purpose_key(text) == _purpose_key(phrase):
            return ""
        text = re.sub(rf"^{re.escape(phrase)}\s*[.:：]?\s*", "", text, flags=re.I)
    if not text or _looks_like_heading(text):
        return ""
    return text


def _looks_like_heading(value: str) -> bool:
    key = _purpose_key(value)
    return key in {
        "효능효과",
        "주효능효과",
        "적응증",
        "사용목적",
        "다음질환",
    }


def _deduplicate_items(values: list[str]) -> list[str]:
    result: list[str] = []
    keys: list[str] = []
    for raw in values:
        value = str(raw or "").strip()
        key = value
        if not key:
            continue
        if key in keys:
            continue
        keys.append(key)
        result.append(value)
    return result


def _without_summary_duplicate(values: list[str], summary: str) -> list[str]:
    summary_key = summary.strip()
    if not summary_key:
        return values
    return [
        value
        for value in values
        if value.strip() != summary_key
    ]


def _purpose_key(value: str) -> str:
    return re.sub(r"[^0-9A-Za-z가-힣]", "", str(value or "")).casefold()


def official_source_hash(medicine: dict[str, Any]) -> str:
    """Versioned exact official snapshot; no number/condition normalization."""
    material = {key: str(medicine.get(key) or "").strip() for key in (
        "medicine_code", "product_name", "manufacturer", "ingredient",
        "efficacy", "usage", "precautions",
    )}
    return "official-v1:" + hashlib.sha256(
        json.dumps(material, ensure_ascii=False, sort_keys=True).encode("utf-8")
    ).hexdigest()


def _complete_user_text(value: str) -> bool:
    text = str(value or "").strip()
    if len(text) < 8:
        return False
    if text.endswith(("및", "또는", "등의", ",", ";", ":", "-")):
        return False
    return True


def _load_list(value: Any) -> list[str]:
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    if not value:
        return []
    try:
        parsed = json.loads(str(value))
    except (json.JSONDecodeError, TypeError):
        parsed = None
    if isinstance(parsed, list):
        return [str(item).strip() for item in parsed if str(item).strip()]
    return [str(value).strip()] if str(value).strip() else []


def _dump(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False)
