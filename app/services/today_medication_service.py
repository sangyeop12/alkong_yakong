"""Today's medicines for the patient home screen (from user_medicines)."""

from __future__ import annotations

import json
import re
from datetime import date
from typing import Any

from fastapi import HTTPException

from app.database import get_connection
from app.services.heart_reading import latest_heart_reading
from app.services.medicine_display import (
    card_official_name,
    ingredient_summary,
    ingredient_strength_from,
    infer_dosage_form,
    is_mock_drug_info_name,
    omit_placeholder_spoken,
    split_ingredients,
    split_take_amount,
)
from app.services.ocr.parser import take_amount_for_display
from app.services.pharmacist.easy_category import (
    derive_easy_spoken_from_medicine,
    display_product_name,
    infer_use_route,
    load_medicine_guidance,
    medicine_guidance_from_medicine,
)

_EXPLICIT_TIME_LABELS = {
    "아침": "08:00",
    "점심": "13:00",
    "저녁": "20:00",
    "취침전": "22:00",
    "자기전": "22:00",
    "MORNING": "08:00",
    "LUNCH": "13:00",
    "AFTERNOON": "13:00",
    "EVENING": "20:00",
    "NIGHT": "22:00",
}


def _confirmed_clock(value: object) -> str | None:
    text = str(value or "").strip()
    if re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", text):
        return text
    return _EXPLICIT_TIME_LABELS.get(re.sub(r"\s+", "", text).upper())


def _match_medicine_codes(match: dict[str, Any], side: str) -> set[str]:
    raw = match.get(f"medicine_codes_{side}") or []
    if isinstance(raw, str):
        raw = [raw]
    if not isinstance(raw, list):
        return set()
    return {str(code).strip() for code in raw if str(code).strip()}


def _is_current_ocr_interaction(
    match: dict[str, Any],
    *,
    active_codes: set[str],
    active_ocr_codes: set[str],
) -> bool:
    """현재 활성 조합이며 OCR 등록약이 포함된 DUR 결과만 홈에 표시한다."""
    codes_a = _match_medicine_codes(match, "a")
    codes_b = _match_medicine_codes(match, "b")
    if not codes_a or not (codes_a & active_codes):
        return False
    if codes_b and not (codes_b & active_codes):
        return False
    return bool((codes_a | codes_b) & active_ocr_codes)


def get_today_medicines(user_id: str, target_date: str | None = None) -> dict[str, Any]:
    uid = (user_id or "").strip()
    if not uid:
        raise HTTPException(status_code=422, detail="user_id가 필요합니다.")
    day = target_date or date.today().isoformat()
    conn = get_connection()
    try:
        user = conn.execute("SELECT id, name FROM users WHERE id = ?", (uid,)).fetchone()
        if not user:
            raise HTTPException(status_code=404, detail="사용자가 없습니다.")

        # 활성 약에 오늘 스케줄이 없으면 만들어 「먹었어요」가 schedule_id 를 쓰게 한다
        _ensure_today_schedules(conn, uid, day)
        usage_select = ""
        medicine_cols = {
            row[1] for row in conn.execute("PRAGMA table_info(medicines)")
        }
        if "usage" in medicine_cols:
            usage_select = ", m.usage"

        schedule_rows = conn.execute(
            f"""
            SELECT ms.id AS schedule_id, ms.time_slot, ms.scheduled_time, ms.status,
                   um.dosage, um.frequency_per_day,
                   m.medicine_code, m.product_name, m.ingredient, m.easy_category,
                   m.efficacy, m.precautions, m.short_explanation,
                   m.explanation_review_status, m.ingredient_strength,
                   m.dosage_form, m.administration_route{usage_select}
            FROM medication_schedules ms
            JOIN user_medicines um ON um.id = ms.user_medicine_id
            JOIN medicines m ON m.medicine_code = um.medicine_code
            WHERE ms.user_id = ? AND ms.scheduled_date = ?
              AND COALESCE(um.is_active, 1) = 1
            ORDER BY ms.scheduled_time, ms.id
            """,
            (uid, day),
        ).fetchall()

        if schedule_rows:
            doses = _doses_from_schedules(schedule_rows, guidance_cursor=conn)
        else:
            doses = []

        guardian = conn.execute(
            """
            SELECT guardian_name, relationship
            FROM guardians WHERE user_id = ?
            ORDER BY id LIMIT 1
            """,
            (uid,),
        ).fetchone()
        active_origin_rows = conn.execute(
            """
            SELECT medicine_code, prescription_item_id
            FROM user_medicines
            WHERE user_id = ? AND COALESCE(is_active, 1) = 1
            """,
            (uid,),
        ).fetchall()
        active_codes = {str(row["medicine_code"]) for row in active_origin_rows}
        active_ocr_codes = {
            str(row["medicine_code"])
            for row in active_origin_rows
            if row["prescription_item_id"] is not None
        }
        course = conn.execute(
            """
            SELECT start_date, end_date
            FROM user_medicines
            WHERE user_id = ? AND COALESCE(is_active, 1) = 1
              AND end_date IS NOT NULL AND end_date >= ?
            ORDER BY end_date LIMIT 1
            """,
            (uid, day),
        ).fetchone()
        heart = latest_heart_reading(conn, uid)
        latest_risk = conn.execute(
            """
            SELECT risk_level, description, total_matches, matches_json
            FROM risk_results
            WHERE user_id = ?
            ORDER BY created_at DESC, id DESC
            LIMIT 1
            """,
            (uid,),
        ).fetchone()
        interaction_alert = None
        interaction_cards: list[dict] = []
        if latest_risk and active_ocr_codes:
            try:
                stored_matches = json.loads(latest_risk["matches_json"] or "[]")
            except (TypeError, json.JSONDecodeError):
                stored_matches = []
            if not isinstance(stored_matches, list):
                stored_matches = []
            stored_matches = [
                match
                for match in stored_matches
                if isinstance(match, dict)
                and _is_current_ocr_interaction(
                    match,
                    active_codes=active_codes,
                    active_ocr_codes=active_ocr_codes,
                )
            ]
            from app.services.dur_service import interaction_priority_cards

            if stored_matches:
                interaction_cards = interaction_priority_cards(stored_matches, conn)
            if (
                str(latest_risk["risk_level"] or "").upper() in {"HIGH", "MEDIUM"}
                and bool(stored_matches)
            ):
                if interaction_cards:
                    first = interaction_cards[0]
                    other = first.get("name_b") or ""
                    interaction_alert = (
                        f"{first.get('name_a')}과 {other}는 함께 먹을 때 주의가 필요해요."
                        if other
                        else str(
                            latest_risk["description"] or "함께 먹을 때 주의가 필요해요."
                        )
                    )
                else:
                    interaction_alert = str(
                        latest_risk["description"] or "함께 먹을 때 주의가 필요해요."
                    )

        return {
            "user_id": uid,
            "date": day,
            "doses": doses,
            "guardian_relation": (
                (guardian["relationship"] if guardian else None) or "보호자"
            ),
            "guardian_name": (guardian["guardian_name"] if guardian else None) or "가족",
            "source": "server",
            "has_server_medicines": bool(doses),
            "interaction_alert": interaction_alert,
            "interaction_cards": interaction_cards,
            "latest_heart_rate": heart["bpm"] if heart else None,
            "latest_heart_rate_normal": heart["normal"] if heart else None,
            **_course_fields(course, day),
        }
    finally:
        conn.close()


def _course_fields(course, day: str) -> dict[str, Any]:
    """가장 먼저 끝나는 처방 기준으로 남은 날을 센다. 끝나는 날을 모르면 비워 둔다."""
    empty = {"days_left": None, "course_started_on": None, "course_total_days": None}
    if course is None:
        return empty
    try:
        end = date.fromisoformat(str(course["end_date"])[:10])
        today = date.fromisoformat(day)
    except ValueError:
        return empty
    try:
        start = date.fromisoformat(str(course["start_date"] or "")[:10])
    except ValueError:
        start = None
    return {
        "days_left": (end - today).days,
        "course_started_on": start.isoformat() if start else None,
        "course_total_days": (end - start).days + 1 if start else None,
    }


def _ensure_today_schedules(conn, user_id: str, day: str) -> None:
    """등록 당시 확인한 실제 HH:MM 시각으로만 오늘 스케줄을 복구한다."""
    active = conn.execute(
        """
        SELECT um.id AS user_medicine_id, um.administration_times,
               um.start_date, um.end_date, um.prescription_item_id
        FROM user_medicines um
        WHERE um.user_id = ? AND COALESCE(um.is_active, 1) = 1
        """,
        (user_id,),
    ).fetchall()
    for row in active:
        if row["start_date"] and str(day) < str(row["start_date"]):
            continue
        if row["end_date"] and str(day) > str(row["end_date"]):
            continue
        um_id = row["user_medicine_id"]
        if row["prescription_item_id"] is not None:
            # 처방으로 붙인 날은 달력이 정한다. 빠진 오늘을 다시 만들지 않는다.
            continue
        exists = conn.execute(
            """
            SELECT 1 FROM medication_schedules
            WHERE user_medicine_id = ? AND scheduled_date = ?
            LIMIT 1
            """,
            (um_id, day),
        ).fetchone()
        if exists:
            continue
        try:
            parsed = json.loads(row["administration_times"] or "[]")
        except (TypeError, json.JSONDecodeError):
            parsed = []
        confirmed_times = [
            clock for value in parsed if (clock := _confirmed_clock(value)) is not None
        ]
        for scheduled_time in dict.fromkeys(confirmed_times):
            time_slot = _slot_from_time(None, scheduled_time).upper()
            conn.execute(
                """
                INSERT OR IGNORE INTO medication_schedules (
                    user_id, user_medicine_id, scheduled_date,
                    scheduled_time, time_slot, status
                ) VALUES (?, ?, ?, ?, ?, 'PENDING')
                """,
                (user_id, um_id, day, scheduled_time, time_slot),
            )
    conn.commit()


def _medicine_item(row, *, guidance_cursor=None) -> dict[str, Any]:
    data = dict(row)
    official_product_name = str(data.get("product_name") or "").strip()
    name = card_official_name(
        product_name=display_product_name(official_product_name),
        display_name=data.get("display_name"),
        ingredient=data.get("ingredient"),
    )
    guidance = (
        load_medicine_guidance(guidance_cursor, data)
        if guidance_cursor is not None
        else medicine_guidance_from_medicine(data)
    )
    spoken = omit_placeholder_spoken(guidance["short_explanation"])
    if "목적으로 처방" in spoken or "목적으로 사용" in spoken:
        easier = omit_placeholder_spoken(derive_easy_spoken_from_medicine(data))
        if easier:
            spoken = easier
    dosage = take_amount_for_display(
        data.get("dosage"),
        times_per_take=data.get("times_per_take"),
    )
    dose_amount, dose_unit = split_take_amount(dosage)
    amount = f"{dose_amount}{dose_unit}" if dose_amount and dose_unit else ""
    ingredient_name = str(data.get("ingredient") or "").strip()
    ingredient_strength = str(data.get("ingredient_strength") or "").strip()
    if not ingredient_strength:
        ingredient_strength = ingredient_strength_from(
            ingredient_name,
            official_product_name,
        )
    dosage_form = str(data.get("dosage_form") or "").strip() or infer_dosage_form(name)
    administration_route = str(data.get("administration_route") or "").strip()
    if not administration_route:
        administration_route = infer_use_route(
            product_name=name,
            usage=data.get("usage"),
            efficacy=data.get("efficacy"),
        )
    structured_purposes = guidance["easy_purposes"]
    purpose_labels = [
        str(value.get("easy_label") or "").strip()
        for value in structured_purposes
        if isinstance(value, dict) and str(value.get("easy_label") or "").strip()
    ]
    structured_cautions = guidance["key_cautions"]
    caution_sentences = [
        str(value.get("short_sentence") or "").strip()
        for value in structured_cautions
        if isinstance(value, dict) and str(value.get("short_sentence") or "").strip()
    ]
    item = {
        "medicine_code": data.get("medicine_code"),
        "display_name": name,
        "official_product_name": official_product_name or name,
        "product_name": name,
        "ingredient_name": ingredient_name,
        "ingredient_summary": ingredient_summary(ingredient_name),
        "ingredients": split_ingredients(ingredient_name),
        "ingredient": ingredient_name,
        "ingredient_strength": ingredient_strength,
        "dosage_form": dosage_form,
        "administration_route": administration_route,
        "dose_amount": dose_amount,
        "dose_unit": dose_unit,
        "amount": amount,
        "easy_category": spoken,
        "purpose_label": guidance["purpose_label"],
        "short_explanation": spoken,
        "purposes": structured_purposes,
        "easy_purposes": purpose_labels,
        "key_caution": guidance["key_caution"],
        "key_cautions": caution_sentences,
        "purpose_notice": guidance["purpose_notice"],
        # 예전 앱은 efficacy를 카드에 그대로 그림. 원문을 넣지 않는다.
        "efficacy": spoken,
    }
    schedule_id = data.get("schedule_id")
    if schedule_id is not None:
        try:
            item["schedule_id"] = int(schedule_id)
        except (TypeError, ValueError):
            pass
    return item


def _visible_medicine_item(row, *, guidance_cursor=None) -> dict[str, Any] | None:
    data = dict(row)
    if str(data.get("medicine_code") or "").upper().startswith("MVP-"):
        return None
    display = card_official_name(
        product_name=display_product_name(data.get("product_name")),
        display_name=data.get("display_name"),
        ingredient=data.get("ingredient"),
    )
    if is_mock_drug_info_name(display):
        return None
    item = _medicine_item(row, guidance_cursor=guidance_cursor)
    if is_mock_drug_info_name(item.get("display_name")):
        return None
    return item


def _slot_from_time(time_slot: str | None, scheduled_time: str | None) -> str:
    raw = f"{time_slot or ''} {scheduled_time or ''}".upper()
    if "MORNING" in raw or "아침" in raw:
        return "morning"
    if "LUNCH" in raw or "AFTERNOON" in raw or "점심" in raw:
        return "lunch"
    if "EVENING" in raw or "NIGHT" in raw or "저녁" in raw:
        return "dinner"
    hour = 8
    try:
        hour = int(str(scheduled_time or "08:00").split(":")[0])
    except ValueError:
        hour = 8
    if hour < 11:
        return "morning"
    if hour < 16:
        return "lunch"
    return "dinner"


def _doses_from_schedules(rows, *, guidance_cursor=None) -> list[dict[str, Any]]:
    buckets: dict[str, dict[str, Any]] = {}
    for row in rows:
        slot = _slot_from_time(row["time_slot"], row["scheduled_time"])
        bucket = buckets.setdefault(
            slot,
            {"slot": slot, "taken": True, "medicines": [], "_codes": set()},
        )
        status = str(row["status"] or "PENDING").upper()
        if status in {"PENDING", "MISSED", "SNOOZED"}:
            bucket["taken"] = False
        code = row["medicine_code"]
        if code in bucket["_codes"]:
            continue
        bucket["_codes"].add(code)
        item = _visible_medicine_item(row, guidance_cursor=guidance_cursor)
        if item is None:
            continue
        bucket["medicines"].append(item)
    order = ("morning", "lunch", "dinner")
    result = []
    for slot in order:
        if slot not in buckets:
            continue
        item = buckets[slot]
        item.pop("_codes", None)
        if item["medicines"]:
            result.append(item)
    return result


def _doses_from_active_medicines(rows, *, guidance_cursor=None) -> list[dict[str, Any]]:
    if not rows:
        return []
    # frequency 기준으로 슬롯에 나눠 담는다.
    buckets: dict[str, list[dict[str, Any]]] = {
        "morning": [],
        "lunch": [],
        "dinner": [],
    }
    for row in rows:
        med = _visible_medicine_item(row, guidance_cursor=guidance_cursor)
        if med is None:
            continue
        times = []
        raw_times = row["administration_times"]
        if isinstance(raw_times, str) and raw_times.strip():
            try:
                parsed = json.loads(raw_times)
                if isinstance(parsed, list):
                    times = [str(t) for t in parsed]
            except json.JSONDecodeError:
                times = []
        if times:
            for t in times:
                buckets[_slot_from_time(None, t)].append(med)
            continue
        # 하루 N회만 있고 실제 시각이 없으면 오늘 화면 시간을 만들어 내지 않는다.

    result = []
    for slot in ("morning", "lunch", "dinner"):
        meds = buckets[slot]
        if not meds:
            continue
        # 같은 약 중복 제거
        uniq = []
        seen = set()
        for med in meds:
            key = med.get("medicine_code") or med.get("ingredient")
            if key in seen:
                continue
            seen.add(key)
            uniq.append(med)
        result.append({"slot": slot, "taken": False, "medicines": uniq})
    return result
