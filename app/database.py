import os
import sqlite3
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
DB_PATH = os.getenv("ALKONGYAKONG_DB_PATH", str(PROJECT_ROOT / "alkongyakong.db"))


def get_connection() -> sqlite3.Connection:
    # Background medicine refreshes may briefly hold the SQLite writer lock.
    # Allow ordinary requests to wait for a short write instead of failing at
    # SQLite's five-second default timeout.
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def purge_ocr_placeholder_rows(conn: sqlite3.Connection | None = None) -> int:
    """예전에 넣은 OCR- 임시 약 행을 스케줄·복용 등록과 함께 지운다."""
    close = False
    if conn is None:
        conn = get_connection()
        close = True
    try:
        cursor = conn.cursor()
        tables = {
            str(row[0])
            for row in cursor.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        }
        if "medicines" not in tables:
            return 0

        if "user_medicines" in tables and "medication_schedules" in tables:
            cursor.execute(
                """
                DELETE FROM medication_schedules
                WHERE user_medicine_id IN (
                    SELECT id FROM user_medicines WHERE medicine_code LIKE 'OCR-%'
                )
                """
            )
        if "user_medicines" in tables and "medication_logs" in tables:
            cursor.execute(
                """
                UPDATE medication_logs
                SET user_medicine_id = NULL
                WHERE user_medicine_id IN (
                    SELECT id FROM user_medicines WHERE medicine_code LIKE 'OCR-%'
                )
                """
            )
        if "user_medicines" in tables:
            cursor.execute(
                "DELETE FROM user_medicines WHERE medicine_code LIKE 'OCR-%'"
            )
        if "prescription_items" in tables:
            cursor.execute(
                """
                UPDATE prescription_items
                SET medicine_code = NULL, match_status = 'UNMATCHED'
                WHERE medicine_code LIKE 'OCR-%'
                """
            )
        cursor.execute("DELETE FROM medicines WHERE medicine_code LIKE 'OCR-%'")
        deleted = cursor.rowcount
        conn.commit()
        return deleted
    finally:
        if close:
            conn.close()
