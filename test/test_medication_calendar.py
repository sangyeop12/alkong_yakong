from datetime import date
import sqlite3

from app.services import dashboard_service
from app.services.dashboard_service import get_medication_calendar
from init_db import TABLE_DEFINITIONS


def test_days_without_schedules_are_not_marked_missed(tmp_path, monkeypatch):
    db_path = tmp_path / "calendar.sqlite3"

    def _open():
        opened = sqlite3.connect(db_path)
        opened.row_factory = sqlite3.Row
        return opened

    conn = _open()
    conn.execute(TABLE_DEFINITIONS["users"])
    conn.execute(TABLE_DEFINITIONS["medicines"])
    conn.execute(TABLE_DEFINITIONS["user_medicines"])
    conn.execute(TABLE_DEFINITIONS["medication_schedules"])
    conn.execute(
        "INSERT INTO users (id, name, role) VALUES ('cal-user', '환자', 'PATIENT')"
    )
    conn.commit()
    conn.close()
    monkeypatch.setattr(dashboard_service, "get_connection", _open)

    today = date.today()
    result = get_medication_calendar("cal-user", today.year, today.month)
    assert result["has_schedules"] is False
    assert all(day["mark"] != "missed" for day in result["days"])
    assert result["missed"] == []
    today_marks = [day["mark"] for day in result["days"] if day["day"] == today.day]
    assert today_marks == ["today"]
