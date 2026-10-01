"""Active user medicines for list and detail screens (one row per medicine code)."""

from __future__ import annotations

import json
from datetime import date
from typing import Any

from fastapi import HTTPException

from app.database import get_connection
from app.services.drug_explain_service import reviewed_detail_payload
from app.services.dur_service import pair_card_fields, person_cautions_for_medicine
from app.services.today_medication_service import _visible_medicine_item


def _parse_administration_times(raw: Any) -> list[str]:
    if isinstance(raw, list):
        return [str(t) for t in raw]
    if isinstance(raw, str) and raw.strip():
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, list):
                return [str(t) for t in parsed]
        except json.JSONDecodeError:
            return []
    return []


def _latest_interaction_result(conn, user_id: str) -> dict[str, Any] | None:
    row = conn.execute(
        """
        SELECT assessment_status, risk_level, description, matches_json, created_at
        FROM risk_results
        WHERE user_id = ?
        ORDER BY created_at DESC, id DESC
        LIMIT 1
        """,
        (user_id,),
    ).fetchone()
    if not row:
        return None
    result = dict(row)
    try:
        matches = json.loads(result.get("matches_json") or "[]")
    except (TypeError, json.JSONDecodeError):
        matches = []
    result["matches"] = matches if isinstance(matches, list) else []
    return result


def _short_drug_name(name: str) -> str:
    text = str(name or "").strip()
    index = text.find("(")
    if index > 0:
        return text[:index].strip()
    return text


def _medicine_in_pair_match(row: dict[str, Any], match: dict[str, Any]) -> bool:
    code = str(row.get("medicine_code") or "").strip()
    product = str(row.get("product_name") or row.get("display_name") or "").strip()
    short = _short_drug_name(product)
    ingredient = str(row.get("ingredient") or "").strip()
    codes = [
        str(value).strip()
        for value in (
            *(match.get("medicine_codes_a") or []),
            *(match.get("medicine_codes_b") or []),
        )
        if str(value).strip()
    ]
    if code and code in codes:
        return True
    names = [
        str(value).strip()
        for value in (
            *(match.get("medicine_names_a") or []),
            *(match.get("medicine_names_b") or []),
        )
        if str(value).strip()
    ]
    if product and product in names:
        return True
    short_names = {_short_drug_name(name) for name in names}
    if short and short in short_names:
        return True
    for value in (match.get("ingredient_a"), match.get("ingredient_b")):
        other = str(value or "").strip()
        if ingredient and other and (other in ingredient or ingredient in other):
            return True
    return False


def _pair_risk_factor(match: dict[str, Any]) -> str:
    return pair_card_fields(match).get("risk_factor") or ""


def _is_pair_interaction(match: dict[str, Any]) -> bool:
    risk = str(match.get("type") or "").strip()
    if risk in {"병용금기", "중복성분", "효능군중복"}:
        return True
    if risk in {"연령금기", "임부금기"}:
        return False
    return bool(match.get("medicine_names_b") or match.get("ingredient_b"))


def _easy_pair_summary(match: dict[str, Any]) -> str:
    return pair_card_fields(match).get("why_easy") or ""


def _interaction_for_medicine(
    row: dict[str, Any],
    latest: dict[str, Any] | None,
) -> dict[str, Any]:
    if latest is None:
        return {
            "interaction_status": "not_checked",
            "interaction_summary": "아직 함께먹기 검사를 하지 않았어요.",
            "interaction_risk_factor": "",
            "interaction_pair_label": "",
            "interaction_matches": [],
        }
    last_prescribed = str(
        row.get("last_prescribed_at") or row.get("start_date") or row.get("created_at") or ""
    )
    if last_prescribed and last_prescribed > str(latest.get("created_at") or ""):
        return {
            "interaction_status": "check_needed",
            "interaction_summary": "이 약을 등록한 뒤 함께먹기 검사가 필요해요.",
            "interaction_risk_factor": "",
            "interaction_pair_label": "",
            "interaction_matches": [],
        }
    assessment = str(latest.get("assessment_status") or "").upper()
    if not assessment:
        assessment = (
            "RISK_FOUND"
            if latest.get("matches")
            else "INCOMPLETE"
            if str(latest.get("risk_level") or "").upper() == "UNKNOWN"
            else "SAFE"
        )
    if assessment == "INCOMPLETE":
        return {
            "interaction_status": "check_needed",
            "interaction_summary": str(latest.get("description") or "함께먹기 검사를 끝내지 못했어요."),
            "interaction_risk_factor": "",
            "interaction_pair_label": "",
            "interaction_matches": [],
        }

    product = str(row.get("product_name") or "").strip()
    relevant: list[dict[str, Any]] = []
    for raw in latest.get("matches") or []:
        if not isinstance(raw, dict):
            continue
        if _is_pair_interaction(raw) and _medicine_in_pair_match(row, raw):
            relevant.append(raw)
    if relevant:
        conflict_names: list[str] = []
        this_short = _short_drug_name(product)
        for match in relevant:
            for value in [
                *(match.get("medicine_names_a") or []),
                *(match.get("medicine_names_b") or []),
            ]:
                name = str(value or "").strip()
                if (
                    name
                    and _short_drug_name(name) != this_short
                    and name not in conflict_names
                ):
                    conflict_names.append(name)
        fields = pair_card_fields(relevant[0])
        return {
            "interaction_status": "risk_found",
            "interaction_risk_level": str(latest.get("risk_level") or "UNKNOWN"),
            "interaction_conflict_names": conflict_names,
            "interaction_summary": fields["why_easy"],
            "interaction_risk_factor": fields["risk_factor"],
            "interaction_pair_label": fields["pair_label"],
            "interaction_matches": relevant,
        }
    return {
        "interaction_status": "none",
        "interaction_risk_level": str(latest.get("risk_level") or "LOW"),
        "interaction_conflict_names": [],
        "interaction_summary": "최근 검사에서 이 약과 관련된 함께먹기 주의를 찾지 못했어요.",
        "interaction_risk_factor": "",
        "interaction_pair_label": "",
        "interaction_matches": [],
    }


def _usage_select(conn) -> str:
    medicine_cols = {row[1] for row in conn.execute("PRAGMA table_info(medicines)")}
    return ", m.usage" if "usage" in medicine_cols else ""


def _active_medicine_rows(conn, user_id: str) -> list[dict[str, Any]]:
    """현재약과 과거약을 합쳐 약 코드당 최신 등록 1건을 반환한다."""
    usage_select = _usage_select(conn)
    rows = conn.execute(
        f"""
        SELECT um.id AS user_medicine_id, um.dosage, um.dose_amount,
               um.dose_unit, um.frequency_per_day, um.administration_times,
               um.start_date, um.end_date, um.is_active, um.status,
               um.created_at, um.last_prescribed_at,
               (SELECT MAX(ml.taken_at)
                  FROM medication_logs ml
                  JOIN medication_schedules ms ON ms.id = ml.schedule_id
                 WHERE ms.user_medicine_id = um.id) AS last_taken_at,
               m.medicine_code, m.product_name, m.ingredient, m.easy_category,
               m.efficacy, m.precautions, m.short_explanation, m.manufacturer,
               m.explanation_review_status, m.ingredient_strength,
               m.dosage_form, m.administration_route{usage_select}
        FROM user_medicines um
        JOIN medicines m ON m.medicine_code = um.medicine_code
        WHERE um.user_id = ? AND um.medicine_code NOT LIKE 'MVP-%'
        ORDER BY um.id DESC
        """,
        (user_id,),
    ).fetchall()
    deduped: list[dict[str, Any]] = []
    seen_codes: set[str] = set()
    for row in rows:
        code = row["medicine_code"]
        if code in seen_codes:
            continue
        seen_codes.add(code)
        deduped.append(dict(row))
    deduped.reverse()
    return deduped


def _enrich_medicine_row(
    row: dict[str, Any],
    *,
    guidance_cursor,
    latest_interaction: dict[str, Any] | None = None,
) -> dict[str, Any] | None:
    item = _visible_medicine_item(row, guidance_cursor=guidance_cursor)
    if item is None:
        return None
    item["dosage"] = row.get("dosage")
    item["frequency_per_day"] = row.get("frequency_per_day")
    item["administration_times"] = _parse_administration_times(
        row.get("administration_times")
    )
    end_date = str(row.get("end_date") or "").strip()
    explicitly_active = bool(row.get("is_active", 1))
    item["status"] = (
        "active"
        if explicitly_active and (not end_date or end_date >= date.today().isoformat())
        else "past"
    )
    item["registered_at"] = row.get("created_at")
    item["last_prescribed_at"] = (
        row.get("last_prescribed_at") or row.get("start_date") or row.get("created_at")
    )
    item["last_taken_at"] = row.get("last_taken_at")
    item.update(_interaction_for_medicine(row, latest_interaction))
    user_medicine_id = row.get("user_medicine_id")
    if user_medicine_id is not None:
        try:
            item["user_medicine_id"] = int(user_medicine_id)
        except (TypeError, ValueError):
            pass
    return item


def get_user_medicines(user_id: str) -> dict[str, Any]:
    uid = (user_id or "").strip()
    if not uid:
        raise HTTPException(status_code=422, detail="user_id가 필요합니다.")

    conn = get_connection()
    try:
        user = conn.execute("SELECT id FROM users WHERE id = ?", (uid,)).fetchone()
        if not user:
            raise HTTPException(status_code=404, detail="사용자가 없습니다.")

        latest_interaction = _latest_interaction_result(conn, uid)
        medicines = [
            item
            for row in _active_medicine_rows(conn, uid)
            if (
                item := _enrich_medicine_row(
                    row,
                    guidance_cursor=conn,
                    latest_interaction=latest_interaction,
                )
            )
            is not None
        ]
        return {
            "user_id": uid,
            "medicines": medicines,
            "has_medicines": bool(medicines),
            "source": "server",
        }
    finally:
        conn.close()


def get_user_medicine(user_id: str, medicine_code: str) -> dict[str, Any]:
    uid = (user_id or "").strip()
    code = (medicine_code or "").strip()
    if not uid:
        raise HTTPException(status_code=422, detail="user_id가 필요합니다.")
    if not code:
        raise HTTPException(status_code=422, detail="medicine_code가 필요합니다.")

    conn = get_connection()
    try:
        user = conn.execute("SELECT id FROM users WHERE id = ?", (uid,)).fetchone()
        if not user:
            raise HTTPException(status_code=404, detail="사용자가 없습니다.")

        usage_select = _usage_select(conn)
        row = conn.execute(
            f"""
            SELECT um.id AS user_medicine_id, um.dosage, um.dose_amount,
                   um.dose_unit, um.frequency_per_day, um.administration_times,
                   um.start_date, um.end_date, um.is_active, um.status,
                   um.created_at, um.last_prescribed_at,
                   (SELECT MAX(ml.taken_at)
                      FROM medication_logs ml
                      JOIN medication_schedules ms ON ms.id = ml.schedule_id
                     WHERE ms.user_medicine_id = um.id) AS last_taken_at,
                   m.medicine_code, m.product_name, m.ingredient, m.easy_category,
                   m.efficacy, m.precautions, m.short_explanation, m.manufacturer,
                   m.explanation_review_status, m.ingredient_strength,
                   m.dosage_form, m.administration_route{usage_select}
            FROM user_medicines um
            JOIN medicines m ON m.medicine_code = um.medicine_code
            WHERE um.user_id = ? AND um.medicine_code = ?
              AND um.medicine_code NOT LIKE 'MVP-%'
            ORDER BY um.id DESC
            LIMIT 1
            """,
            (uid, code),
        ).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="해당 약을 찾을 수 없습니다.")

        source_row = dict(row)
        medicine = _enrich_medicine_row(
            source_row,
            guidance_cursor=conn,
            latest_interaction=_latest_interaction_result(conn, uid),
        )
        if medicine is None:
            raise HTTPException(status_code=404, detail="해당 약을 찾을 수 없습니다.")

        person_cautions = person_cautions_for_medicine(
            conn,
            user_id=uid,
            medicine=source_row,
        )
        medicine["key_caution"] = person_cautions[0] if person_cautions else None
        medicine["key_cautions"] = person_cautions

        detail = reviewed_detail_payload(conn.cursor(), source_row)
        reviewed_safety = detail.get("safety") or {}
        detail["medicine"] = {
            **(detail.get("medicine") or {}),
            **medicine,
            "manufacturer": row["manufacturer"],
        }
        detail["patient_dosage"] = {
            "amount": medicine.get("amount") or "",
            "dosage": medicine.get("dosage"),
            "frequency_per_day": medicine.get("frequency_per_day"),
            "administration_times": medicine.get("administration_times") or [],
        }
        detail["safety"] = {
            **reviewed_safety,
            "key_cautions": person_cautions,
            "interaction_status": medicine.get("interaction_status"),
            "interaction_summary": medicine.get("interaction_summary"),
            "interaction_risk_level": medicine.get("interaction_risk_level"),
            "interaction_risk_factor": medicine.get("interaction_risk_factor")
            or "",
            "interaction_pair_label": medicine.get("interaction_pair_label")
            or "",
            "interaction_conflict_names": medicine.get(
                "interaction_conflict_names"
            )
            or [],
        }
        detail["user_id"] = uid
        detail["response_source"] = "server"
        return detail
    finally:
        conn.close()
