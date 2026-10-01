"""지난 복약 기록을 날짜별로 묶는다. 기록 탭과 달력이 같은 숫자를 쓴다."""

from __future__ import annotations

from collections import defaultdict
from datetime import date
from typing import Any

from fastapi import HTTPException

from app.database import get_connection
from app.services.today_medication_service import _slot_from_time

_SLOT_ORDER = ("morning", "lunch", "dinner")
_SLOT_LABELS = {"morning": "아침", "lunch": "점심", "dinner": "저녁"}
_MAX_DAYS = 120


def _parse_day(value: str, field: str) -> date:
    try:
        return date.fromisoformat(value)
    except (TypeError, ValueError) as error:
        raise HTTPException(
            status_code=422, detail=f"{field}는 YYYY-MM-DD 형식이어야 합니다."
        ) from error


def get_medication_history(user_id: str, start: str, end: str) -> dict[str, Any]:
    first = _parse_day(start, "start")
    last = _parse_day(end, "end")
    if last < first:
        raise HTTPException(status_code=422, detail="end가 start보다 앞설 수 없습니다.")
    if (last - first).days >= _MAX_DAYS:
        raise HTTPException(
            status_code=422, detail=f"한 번에 {_MAX_DAYS}일까지만 볼 수 있습니다."
        )

    conn = get_connection()
    try:
        if not conn.execute("SELECT 1 FROM users WHERE id = ?", (user_id,)).fetchone():
            raise HTTPException(status_code=404, detail="사용자가 없습니다.")
        rows = conn.execute(
            """
            SELECT ms.scheduled_date, ms.time_slot, ms.scheduled_time, ms.status
            FROM medication_schedules ms
            JOIN user_medicines um ON um.id = ms.user_medicine_id
            WHERE ms.user_id = ? AND ms.scheduled_date BETWEEN ? AND ?
              AND UPPER(um.medicine_code) NOT LIKE 'MVP-%'
            """,
            (user_id, first.isoformat(), last.isoformat()),
        ).fetchall()
    finally:
        conn.close()

    # 한 시간대의 약을 모두 드셔야 그 시간대를 드신 것으로 본다.
    slots_by_day: dict[str, dict[str, bool]] = defaultdict(dict)
    for row in rows:
        slot = _slot_from_time(row["time_slot"], row["scheduled_time"])
        taken = str(row["status"] or "").upper() == "TAKEN"
        day_slots = slots_by_day[str(row["scheduled_date"])]
        day_slots[slot] = day_slots.get(slot, True) and taken

    days = []
    for day_key in sorted(slots_by_day):
        day_slots = slots_by_day[day_key]
        ordered = [slot for slot in _SLOT_ORDER if slot in day_slots]
        days.append(
            {
                "date": day_key,
                "total": len(ordered),
                "taken": sum(1 for slot in ordered if day_slots[slot]),
                "missed_slots": [
                    _SLOT_LABELS[slot] for slot in ordered if not day_slots[slot]
                ],
            }
        )
    return {
        "user_id": user_id,
        "start": first.isoformat(),
        "end": last.isoformat(),
        "days": days,
    }
