from datetime import datetime, timedelta, timezone

from fastapi import HTTPException

from app.database import get_connection
from app.models.schemas import HeartRateCreate


def save_heart_rate(request: HeartRateCreate) -> dict:
    conn = get_connection()
    try:
        cursor = conn.cursor()
        if not cursor.execute(
            "SELECT 1 FROM users WHERE id = ?", (request.user_id,)
        ).fetchone():
            raise HTTPException(status_code=404, detail="사용자가 없습니다.")

        measured_at = request.measured_at or datetime.now().isoformat(timespec="seconds")
        cursor.execute(
            """
            INSERT INTO heart_rate_logs (
                user_id, bpm, measured_at, device_id, source, measurement_context
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                request.user_id,
                request.bpm,
                measured_at,
                request.device_id,
                request.source,
                request.measurement_context,
            ),
        )
        log_id = cursor.lastrowid
        baseline = cursor.execute(
            "SELECT * FROM baseline_heart_rate WHERE user_id = ?",
            (request.user_id,),
        ).fetchone()

        conn.commit()
        response_time = _time_with_zone(measured_at)
        return {
            "heart_rate_log_id": log_id,
            "bpm": request.bpm,
            "measured_at": response_time.isoformat() if response_time else measured_at,
            "measurement_context": request.measurement_context,
            "baseline": dict(baseline) if baseline else None,
            "abnormal_event": None,
        }
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def get_abnormal_events(user_id: str) -> list[dict]:
    conn = get_connection()
    try:
        rows = conn.execute(
            """
            SELECT * FROM abnormal_events
            WHERE user_id = ?
            ORDER BY occurred_at DESC, id DESC
            """,
            (user_id,),
        ).fetchall()
        return [dict(row) for row in rows]
    finally:
        conn.close()


# ── 심박수 요약 ────────────────────────────────────────────────
#
# 사용자가 복약 전·후로 표시한 심박 기록만 비교 자료로 묶는다.
# 일반 측정은 저장·표시하되 시각만 보고 복약 전·후로 추정하지 않는다.

_WEEKDAY_LABELS = ["월", "화", "수", "목", "금", "토", "일"]


def _parse(value: str) -> datetime | None:
    """DB 의 시각 문자열을 datetime 으로. 형식이 섞여 있어도 죽지 않는다."""
    if not value:
        return None
    text = str(value).strip().replace("T", " ")
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            return datetime.strptime(text[: len(fmt) + 2].strip(), fmt)
        except ValueError:
            continue
    return None


def _pair_for_date(readings: list[tuple[datetime, int, str]]) -> dict:
    """사용자가 직접 표시한 복약 전·후 측정 한 쌍.

    시각만 보고 목적을 추정하지 않는다. 같은 날 같은 목적을 여러 번 재면
    가장 최근 기록을 대표로 둔다.
    """
    before = None
    after = None
    for measured_at, bpm, measurement_context in readings:
        if measurement_context == "before_medication":
            if before is None or measured_at > before[0]:
                before = (measured_at, bpm)
        elif measurement_context == "after_medication":
            if after is None or measured_at > after[0]:
                after = (measured_at, bpm)
    return {
        "before": before[1] if before else None,
        "after": after[1] if after else None,
        "before_at": before[0].strftime("%H:%M") if before else None,
        "after_at": after[0].strftime("%H:%M") if after else None,
    }


def _slot_label(taken_at: datetime) -> str:
    if taken_at.hour < 11:
        return "아침 약"
    if taken_at.hour < 16:
        return "점심 약"
    return "저녁 약"


def _time_with_zone(value: str, *, naive_is_utc: bool = False) -> datetime | None:
    """Legacy writer uses server-local datetime.now(); retain that interpretation.

    Explicit offsets always win. No stored timestamp is rewritten.
    """
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        if parsed.tzinfo is None and naive_is_utc:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)
    except (ValueError, TypeError):
        return None


def get_heart_summary(
    user_id: str, today: datetime | None = None, *,
    include_readings: bool = False, utc_offset_minutes: int = 0,
) -> dict:
    """심박수 화면 하나가 쓰는 것을 한 번에 돌려준다.

    화면이 오늘·이번 주·한 달을 따로 부르면 요청이 세 번이 되고, 그 사이
    날짜가 바뀌면 서로 다른 기준의 숫자가 한 화면에 놓인다.
    """
    now = today or datetime.now()
    zone = timezone(timedelta(minutes=utc_offset_minutes))
    if include_readings:
        now = now.astimezone(zone)

    def parse(value, *, medication=False):
        if not include_readings:
            return _parse(value)
        # TAKEN writer uses SQLite CURRENT_TIMESTAMP (UTC), unlike heart writer.
        parsed = _time_with_zone(value, naive_is_utc=medication)
        return parsed.astimezone(zone) if parsed else None

    actual_readings = []
    first_day = min(now.date().replace(day=1), now.date() - timedelta(days=now.weekday()))
    conn = get_connection()
    try:
        cursor = conn.cursor()
        if not cursor.execute(
            "SELECT 1 FROM users WHERE id = ?", (user_id,)
        ).fetchone():
            raise HTTPException(status_code=404, detail="사용자가 없습니다.")

        # 한 달치만 읽는다. 화면이 그 이상을 보여주지 않는다.
        since = (now - timedelta(days=31)).isoformat(timespec="seconds")
        if include_readings:
            # Broad lexical bound, then exact local-calendar filtering below.
            since = (now - timedelta(days=33)).date().isoformat()

        readings: list[tuple[datetime, int, str]] = []
        for row in cursor.execute(
            """
            SELECT id, measured_at, bpm, measurement_context FROM heart_rate_logs
            WHERE user_id = ? AND measured_at >= ?
            ORDER BY measured_at
            """,
            (user_id, since),
        ).fetchall():
            measured_at = parse(row["measured_at"])
            if measured_at:
                measurement_context = row["measurement_context"] or "general"
                readings.append((measured_at, int(row["bpm"]), measurement_context))
                if include_readings:
                    if first_day <= measured_at.date() <= now.date():
                        actual_readings.append({
                            "id": row["id"], "bpm": int(row["bpm"]),
                            "measured_at": measured_at.isoformat(),
                            "measurement_context": measurement_context,
                        })

        takes: list[datetime] = []
        for row in cursor.execute(
            """
            SELECT taken_at FROM medication_logs
            WHERE user_id = ? AND taken_at >= ? AND status = 'TAKEN'
            ORDER BY taken_at
            """,
            (user_id, since),
        ).fetchall():
            taken_at = parse(row["taken_at"], medication=True)
            if taken_at:
                takes.append(taken_at)
    finally:
        conn.close()

    readings_by_date: dict[str, list[tuple[datetime, int, str]]] = {}
    for reading in readings:
        readings_by_date.setdefault(reading[0].date().isoformat(), []).append(reading)

    takes_by_date = {taken_at.date().isoformat(): taken_at for taken_at in takes}
    by_date: dict[str, dict] = {}
    for key, dated_readings in readings_by_date.items():
        pair = _pair_for_date(dated_readings)
        if pair["before"] is None and pair["after"] is None:
            continue
        taken_at = takes_by_date.get(key)
        by_date[key] = {
            **pair,
            "slot_label": _slot_label(taken_at) if taken_at else "복약",
        }

    today_key = now.date().isoformat()
    today_pair = by_date.get(today_key, {})

    monday = now.date() - timedelta(days=now.weekday())
    week = []
    for offset in range(7):
        date = monday + timedelta(days=offset)
        entry = by_date.get(date.isoformat(), {})
        week.append(
            {
                "weekday": _WEEKDAY_LABELS[offset],
                "before": entry.get("before"),
                "after": entry.get("after"),
            }
        )

    month = []
    for day in range(1, now.day + 1):
        date = now.date().replace(day=day)
        entry = by_date.get(date.isoformat(), {})
        month.append(
            {
                "day": day,
                "before": entry.get("before"),
                "after": entry.get("after"),
            }
        )

    result = {
        "today": {
            "before": today_pair.get("before"),
            "after": today_pair.get("after"),
        },
        "today_slot_label": today_pair.get("slot_label") or "저녁 약",
        "before_at": today_pair.get("before_at"),
        "after_at": today_pair.get("after_at"),
        "week": week,
        "month": month,
        "streak_days": _streak(month),
        "best_streak_days": _best_streak(month),
        "anomaly": _anomaly(month, now),
    }
    if include_readings:
        result["readings"] = sorted(actual_readings, key=lambda row: row["measured_at"], reverse=True)
        result["period_date"] = now.date().isoformat()
    return result


def _streak(month: list[dict]) -> int:
    """오늘부터 거슬러 올라가며 실제로 측정한 날을 센다.

    BPM 숫자에 고정 정상 범위를 적용하지 않는다.
    """
    count = 0
    for entry in reversed(month):
        if entry.get("after") is None:
            continue
        count += 1
    return count


def _best_streak(month: list[dict]) -> int:
    best = 0
    current = 0
    for entry in month:
        if entry.get("after") is None:
            continue
        current += 1
        best = max(best, current)
    return best


def _anomaly(month: list[dict], now: datetime) -> dict | None:
    """고정 BPM 기준으로 이상일을 자동 판정하지 않는다."""
    return None
