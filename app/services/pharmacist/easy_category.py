"""Derive a short senior-friendly medicine category for UI parentheses."""

from __future__ import annotations

import re
import sqlite3
from typing import Any

from app.services.medicine_display import (
    card_purpose_label,
    omit_placeholder_spoken,
    strip_export_alias,
)
from app.services.pharmacist.easy_category_db import (
    FALLBACK_SPOKEN,
    lookup_easy_label,
    lookup_easy_matches,
    lookup_spoken_sentence,
)

_PATCH = ("붙이", "첩부", "파스", "플라스타", "플라스터", "패취", "반창고")
_APPLY = ("바르", "도포", "외용", "연고", "크림", "로션")
_EYE = ("점안", "안연고")
_EAT = ("경구", "복용", "정제", "캡슐", "시럽", "현탁")

PURPOSE_NOTICE = (
    "허가된 쓰임을 쉽게 설명한 내용이에요. 내가 처방받은 이유는 의사나 약사에게 확인해 주세요."
)

# 긴 효능 문장에서 독립적으로 확인해도 의미가 흐려지지 않는 문구만 둔다.
# 단순 단어 나열로 모든 효능을 추측하지 않고, 검토된 규칙을 조금씩 늘린다.
_CONTEXT_PURPOSE_RULES: tuple[dict[str, Any], ...] = (
    {
        "purpose_code": "ITCH_RELIEF",
        "easy_label": "가려움 완화",
        "sentence": "가려움을 줄이는 데 쓰이는 약이에요.",
        "phrases": ("수반하는 가려움", "가려움증", "두드러기"),
    },
    {
        "purpose_code": "ANXIETY_TENSION_RELIEF",
        "easy_label": "불안·긴장 완화",
        "sentence": "불안이나 긴장을 줄이는 데 쓰이는 약이에요.",
        "phrases": (
            "신경증에서의 불안",
            "불안, 긴장, 초조",
            "불안ㆍ긴장ㆍ초조",
            "불안장애의 치료",
            "불안증상",
            "공황장애",
        ),
    },
)


def infer_use_route(
    *,
    product_name: str | None = None,
    usage: str | None = None,
    efficacy: str | None = None,
) -> str:
    name = str(product_name or "")
    usage_text = str(usage or "")
    efficacy_text = str(efficacy or "")
    blob = f"{name} {usage_text}"
    if any(token in blob for token in _PATCH):
        return "patch"
    if any(token in blob for token in _EYE):
        return "eye"
    if any(token in blob for token in _APPLY):
        return "apply"
    if "액" in name and any(
        token in efficacy_text for token in ("피부", "습진", "피부염", "가려움", "건선")
    ):
        return "apply"
    if any(token in blob for token in _EAT):
        return "eat"
    return "eat"


def display_product_name(name: str | None) -> str:
    """수출명·군더더기 괄호를 떼고 카드에 쓸 제품명."""
    return strip_export_alias(name)


def derive_easy_category(
    *,
    product_name: str | None = None,
    ingredient: str | None = None,
    efficacy: str | None = None,
    usage: str | None = None,
    source_text: str | None = None,
) -> str | None:
    """Look up easy_category_map.db using official name/efficacy text."""
    name_blob = " ".join(str(part or "") for part in (product_name, ingredient))
    # 복용법·주의는 분류에 쓰지 않는다. 주의의 '알레르기'가 약 효능처럼 붙는 것을 막는다.
    efficacy_blob = str(efficacy or "")
    if not name_blob.strip() and not efficacy_blob.strip():
        return None
    return lookup_easy_label(name_text=name_blob, efficacy_text=efficacy_blob)


def derive_easy_spoken(
    *,
    product_name: str | None = None,
    ingredient: str | None = None,
    efficacy: str | None = None,
    usage: str | None = None,
) -> str:
    """홈·OCR 카드용 B 문장. 허가 원문을 다시 쓰지 않는다."""
    label = derive_easy_category(
        product_name=product_name,
        ingredient=ingredient,
        efficacy=efficacy,
        usage=usage,
    )
    route = infer_use_route(
        product_name=product_name,
        usage=usage,
        efficacy=efficacy,
    )
    if not label:
        return FALLBACK_SPOKEN
    return lookup_spoken_sentence(label, route)


def derive_easy_category_from_medicine(med: dict[str, Any]) -> str | None:
    return derive_easy_category(
        product_name=med.get("product_name") or med.get("medicine_name"),
        ingredient=med.get("ingredient"),
        efficacy=med.get("efficacy") or med.get("efficacy_text"),
    )


def derive_easy_spoken_from_medicine(med: dict[str, Any]) -> str:
    return derive_easy_spoken(
        product_name=med.get("product_name") or med.get("medicine_name"),
        ingredient=med.get("ingredient"),
        efficacy=med.get("efficacy") or med.get("efficacy_text"),
        usage=med.get("usage") or med.get("usage_text"),
    )


def _purpose_from_legacy_label(
    label: str,
    *,
    route: str,
    evidence_type: str,
    evidence_text: str,
) -> dict[str, str]:
    return {
        "purpose_code": label,
        "easy_label": label,
        "sentence": lookup_spoken_sentence(label, route),
        "evidence_type": evidence_type,
        "evidence_text": evidence_text,
        "source": "식약처 허가정보 기반 분류 사전",
        "confidence": "HIGH" if evidence_type == "NAME_OR_INGREDIENT" else "MEDIUM",
        "review_status": "DERIVED",
    }


def derive_easy_purposes_from_medicine(med: dict[str, Any]) -> list[dict[str, str]]:
    """Return patient-friendly purposes without claiming the patient's diagnosis."""
    product_name = med.get("product_name") or med.get("medicine_name")
    ingredient = med.get("ingredient")
    efficacy = str(med.get("efficacy") or med.get("efficacy_text") or "")
    usage = med.get("usage") or med.get("usage_text")
    name_blob = " ".join(str(part or "") for part in (product_name, ingredient))
    route = infer_use_route(
        product_name=str(product_name or ""),
        usage=str(usage or ""),
        efficacy=efficacy,
    )

    mapped = lookup_easy_matches(name_text=name_blob, efficacy_text=efficacy)
    name_matches = [row for row in mapped if row["match_scope"] == "name"]
    if name_matches:
        row = name_matches[0]
        return [
            _purpose_from_legacy_label(
                row["easy_label"],
                route=route,
                evidence_type="NAME_OR_INGREDIENT",
                evidence_text=row["official_phrase"],
            )
        ]

    purposes: list[dict[str, str]] = []
    for rule in _CONTEXT_PURPOSE_RULES:
        evidence = next(
            (phrase for phrase in rule["phrases"] if phrase in efficacy),
            None,
        )
        if not evidence:
            continue
        purposes.append(
            {
                "purpose_code": str(rule["purpose_code"]),
                "easy_label": str(rule["easy_label"]),
                "sentence": str(rule["sentence"]),
                "evidence_type": "OFFICIAL_EFFICACY",
                "evidence_text": evidence,
                "source": "식약처 허가 효능",
                "confidence": "HIGH",
                "review_status": "DERIVED",
            }
        )
    if purposes:
        return purposes

    efficacy_matches = [row for row in mapped if row["match_scope"] == "efficacy"]
    if efficacy_matches:
        row = efficacy_matches[0]
        return [
            _purpose_from_legacy_label(
                row["easy_label"],
                route=route,
                evidence_type="OFFICIAL_EFFICACY",
                evidence_text=row["official_phrase"],
            )
        ]
    return []


_CAUTION_RULES: tuple[dict[str, Any], ...] = (
    {
        "caution_code": "DROWSINESS_DRIVING",
        "short_sentence": "졸리거나 어지러울 수 있어요. 운전이나 위험한 기계 조작은 피하세요.",
        "keywords": ("졸음", "운전", "기계조작", "기계 조작"),
        "evidence_text": "졸음 및 운전·기계조작 주의",
    },
    {
        "caution_code": "PREGNANCY",
        "short_sentence": "임신 중이거나 임신 가능성이 있으면 의사·약사에게 먼저 알려 주세요.",
        "keywords": ("임부", "임산부", "임신 중"),
        "evidence_text": "임신 관련 주의",
    },
    {
        "caution_code": "LIVER_KIDNEY",
        "short_sentence": "간이나 콩팥(신장)이 약한 분은 의사·약사와 상의하세요.",
        "keywords": ("간장애", "간기능", "신장애", "신기능", "신부전", "간부전", "신장"),
        "evidence_text": "간·신장 주의",
    },
    {
        "caution_code": "ALCOHOL",
        "short_sentence": "이 약을 먹는 동안 술은 피하는 것이 좋아요.",
        "keywords": ("알코올", "음주"),
        "evidence_text": "음주 주의",
    },
    {
        "caution_code": "BLEEDING",
        "short_sentence": "피가 잘 멈추지 않거나 멍이 잘 들면 의사·약사에게 알려 주세요.",
        "keywords": ("항응고", "출혈경향", "출혈 경향"),
        "evidence_text": "출혈 주의",
    },
)


def derive_key_cautions_from_medicine(med: dict[str, Any]) -> list[dict[str, str]]:
    """Short, evidence-linked cautions from official precautions text."""
    precautions = str(med.get("precautions") or med.get("cautions") or "")
    if not precautions.strip():
        return []
    found: list[dict[str, str]] = []
    for rule in _CAUTION_RULES:
        evidence = next(
            (phrase for phrase in rule["keywords"] if phrase in precautions),
            None,
        )
        if not evidence:
            continue
        found.append(
            {
                "caution_code": str(rule["caution_code"]),
                "short_sentence": str(rule["short_sentence"]),
                "evidence_text": str(rule["evidence_text"]),
                "source": "식약처 허가 주의사항",
                "severity": "CAUTION",
                "review_status": "DERIVED",
            }
        )
        if len(found) >= 3:
            break
    return found


def _compose_guidance(
    purposes: list[dict[str, str]], cautions: list[dict[str, str]]
) -> dict[str, Any]:
    if len(purposes) == 1:
        short_explanation = omit_placeholder_spoken(purposes[0].get("sentence"))
    elif purposes:
        labels = [str(item.get("easy_label") or "").strip() for item in purposes]
        labels = [label.removesuffix(" 완화") for label in labels if label]
        short_explanation = (
            " 또는 ".join(labels[:3]) + "을 완화할 목적으로 사용될 수 있어요."
        )
    else:
        short_explanation = ""
    return {
        "easy_purposes": purposes,
        "purpose_label": card_purpose_label(purposes),
        "short_explanation": short_explanation,
        "key_cautions": cautions,
        "key_caution": cautions[0]["short_sentence"] if cautions else None,
        "purpose_notice": PURPOSE_NOTICE,
    }


def _apply_reviewed_short_explanation(
    guidance: dict[str, Any],
    med: dict[str, Any],
) -> dict[str, Any]:
    sentence = str(med.get("short_explanation") or "").strip()
    status = str(med.get("explanation_review_status") or "").upper()
    if sentence and status == "REVIEWED":
        return {**guidance, "short_explanation": sentence}
    return guidance


def medicine_guidance_from_medicine(med: dict[str, Any]) -> dict[str, Any]:
    return _apply_reviewed_short_explanation(
        _compose_guidance(
            derive_easy_purposes_from_medicine(med),
            derive_key_cautions_from_medicine(med),
        ),
        med,
    )


def load_medicine_guidance(cursor: Any, med: dict[str, Any]) -> dict[str, Any]:
    """Prefer pharmacist-reviewed persisted guidance, then derived persisted rows."""
    medicine_code = str(med.get("medicine_code") or "").strip()
    if not medicine_code:
        return medicine_guidance_from_medicine(med)
    try:
        purpose_result = cursor.execute(
            """
                SELECT purpose_code, easy_label, easy_sentence AS sentence,
                       evidence_type, evidence_text, source, confidence, review_status
                FROM medicine_purposes
                WHERE medicine_code = ?
                ORDER BY CASE review_status WHEN 'REVIEWED' THEN 0 ELSE 1 END,
                         priority, id
            """,
            (medicine_code,),
        )
        purpose_columns = [item[0] for item in purpose_result.description or []]
        purpose_rows = [
            dict(row)
            if hasattr(row, "keys")
            else dict(zip(purpose_columns, row))
            for row in purpose_result.fetchall()
        ]
        caution_result = cursor.execute(
            """
                SELECT caution_code, short_sentence, evidence_text, source,
                       severity, review_status
                FROM medicine_key_cautions
                WHERE medicine_code = ?
                ORDER BY CASE review_status WHEN 'REVIEWED' THEN 0 ELSE 1 END, id
            """,
            (medicine_code,),
        )
        caution_columns = [item[0] for item in caution_result.description or []]
        caution_rows = [
            dict(row)
            if hasattr(row, "keys")
            else dict(zip(caution_columns, row))
            for row in caution_result.fetchall()
        ]
    except sqlite3.OperationalError:
        return medicine_guidance_from_medicine(med)

    reviewed_purposes = [
        row for row in purpose_rows if row.get("review_status") == "REVIEWED"
    ]
    reviewed_cautions = [
        row for row in caution_rows if row.get("review_status") == "REVIEWED"
    ]
    purposes = reviewed_purposes or purpose_rows
    cautions = reviewed_cautions or caution_rows
    if not purposes and not cautions:
        return medicine_guidance_from_medicine(med)
    if not cautions:
        cautions = derive_key_cautions_from_medicine(med)
    return _apply_reviewed_short_explanation(
        _compose_guidance(purposes, cautions),
        med,
    )


def sync_medicine_guidance(cursor: Any, med: dict[str, Any]) -> dict[str, Any]:
    """Persist derived guidance while preserving pharmacist-reviewed rows."""
    guidance = medicine_guidance_from_medicine(med)
    medicine_code = str(med.get("medicine_code") or "").strip()
    if not medicine_code:
        return guidance

    purpose_codes: list[str] = []
    for priority, purpose in enumerate(guidance["easy_purposes"], start=1):
        purpose_code = str(purpose["purpose_code"])
        purpose_codes.append(purpose_code)
        cursor.execute(
            """
            INSERT INTO medicine_purposes (
                medicine_code, purpose_code, easy_label, easy_sentence,
                evidence_type, evidence_text, source, confidence,
                review_status, classifier_version, priority
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, '2.0', ?)
            ON CONFLICT(medicine_code, purpose_code) DO UPDATE SET
                easy_label = excluded.easy_label,
                easy_sentence = excluded.easy_sentence,
                evidence_type = excluded.evidence_type,
                evidence_text = excluded.evidence_text,
                source = excluded.source,
                confidence = excluded.confidence,
                classifier_version = excluded.classifier_version,
                priority = excluded.priority,
                updated_at = CURRENT_TIMESTAMP
            WHERE medicine_purposes.review_status != 'REVIEWED'
            """,
            (
                medicine_code,
                purpose_code,
                purpose["easy_label"],
                purpose["sentence"],
                purpose["evidence_type"],
                purpose.get("evidence_text"),
                purpose["source"],
                purpose["confidence"],
                purpose["review_status"],
                priority,
            ),
        )
    if purpose_codes:
        placeholders = ", ".join("?" for _ in purpose_codes)
        cursor.execute(
            f"""
            DELETE FROM medicine_purposes
            WHERE medicine_code = ? AND review_status = 'DERIVED'
              AND purpose_code NOT IN ({placeholders})
            """,
            (medicine_code, *purpose_codes),
        )
    else:
        cursor.execute(
            "DELETE FROM medicine_purposes WHERE medicine_code = ? AND review_status = 'DERIVED'",
            (medicine_code,),
        )

    caution_codes: list[str] = []
    for caution in guidance["key_cautions"]:
        caution_code = str(caution["caution_code"])
        caution_codes.append(caution_code)
        cursor.execute(
            """
            INSERT INTO medicine_key_cautions (
                medicine_code, caution_code, short_sentence, evidence_text,
                source, severity, review_status, classifier_version
            ) VALUES (?, ?, ?, ?, ?, ?, ?, '2.0')
            ON CONFLICT(medicine_code, caution_code) DO UPDATE SET
                short_sentence = excluded.short_sentence,
                evidence_text = excluded.evidence_text,
                source = excluded.source,
                severity = excluded.severity,
                classifier_version = excluded.classifier_version,
                updated_at = CURRENT_TIMESTAMP
            WHERE medicine_key_cautions.review_status != 'REVIEWED'
            """,
            (
                medicine_code,
                caution_code,
                caution["short_sentence"],
                caution.get("evidence_text"),
                caution["source"],
                caution["severity"],
                caution["review_status"],
            ),
        )
    if caution_codes:
        placeholders = ", ".join("?" for _ in caution_codes)
        cursor.execute(
            f"""
            DELETE FROM medicine_key_cautions
            WHERE medicine_code = ? AND review_status = 'DERIVED'
              AND caution_code NOT IN ({placeholders})
            """,
            (medicine_code, *caution_codes),
        )
    else:
        cursor.execute(
            "DELETE FROM medicine_key_cautions WHERE medicine_code = ? AND review_status = 'DERIVED'",
            (medicine_code,),
        )
    return load_medicine_guidance(cursor, med)


def backfill_all_medicine_guidance(cursor: Any | None = None) -> int:
    """Re-derive and persist purposes/cautions for every medicines row."""
    owns_connection = cursor is None
    if owns_connection:
        from app.database import get_connection

        conn = get_connection()
        cursor = conn
    else:
        conn = None
    try:
        rows = cursor.execute("SELECT * FROM medicines").fetchall()
        updated = 0
        for row in rows:
            sync_medicine_guidance(cursor, dict(row))
            updated += 1
        if conn is not None:
            conn.commit()
        return updated
    finally:
        if owns_connection and conn is not None:
            conn.close()


def format_display_name(name: str, easy_category: str | None) -> str:
    base = (name or "").strip()
    category = (easy_category or "").strip()
    if not base:
        return category
    if not category:
        return base
    return f"{base} ({category})"
