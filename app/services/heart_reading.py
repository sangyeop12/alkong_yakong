"""가장 최근에 잰 심박수 한 번. 홈 바로가기와 보호자 현황이 같이 쓴다."""

from __future__ import annotations

import sqlite3

# 기준값이 아직 없을 때 쓰는 범위. 앱의 HeartSensor와 같다.
_NORMAL_LOW = 50
_NORMAL_HIGH = 110


def latest_heart_reading(conn: sqlite3.Connection, user_id: str) -> dict | None:
    row = conn.execute(
        """
        SELECT bpm, measured_at FROM heart_rate_logs
        WHERE user_id = ?
        ORDER BY measured_at DESC, id DESC
        LIMIT 1
        """,
        (user_id,),
    ).fetchone()
    if row is None:
        return None
    baseline = conn.execute(
        "SELECT min_normal_bpm, max_normal_bpm FROM baseline_heart_rate WHERE user_id = ?",
        (user_id,),
    ).fetchone()
    low, high = (
        (baseline["min_normal_bpm"], baseline["max_normal_bpm"])
        if baseline
        else (_NORMAL_LOW, _NORMAL_HIGH)
    )
    bpm = int(row["bpm"])
    return {"bpm": bpm, "measured_at": row["measured_at"], "normal": low <= bpm <= high}
