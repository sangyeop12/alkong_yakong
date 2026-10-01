import os
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import init_db
from app.models.schemas import HeartRateCreate
from app.models.response_schemas import HeartRateResponse
from app.services import biosignal_service


class BiosignalPolicyTest(unittest.TestCase):
    def test_heart_rate_post_only_records_operational_average(self):
        handle, path = tempfile.mkstemp(suffix=".db")
        os.close(handle)
        try:
            with patch.object(init_db, "DB_PATH", path):
                init_db.initialize_database()
            conn = sqlite3.connect(path)
            conn.execute(
                "INSERT INTO users (id, name, role) VALUES ('U1', '테스트', 'PATIENT')"
            )
            conn.execute(
                """
                INSERT INTO guardians (
                    id, user_id, guardian_name, relationship,
                    phone, notification_enabled
                ) VALUES ('G1', 'U1', '보호자', '가족', '01000000000', 1)
                """
            )
            conn.commit()
            conn.close()

            def connection():
                candidate = sqlite3.connect(path)
                candidate.row_factory = sqlite3.Row
                candidate.execute("PRAGMA foreign_keys = ON")
                return candidate

            with patch.object(biosignal_service, "get_connection", connection):
                result = biosignal_service.save_heart_rate(
                    HeartRateCreate(
                        user_id="U1",
                        bpm=160,
                        source="POLAR_30S_AVERAGE",
                    )
                )

            conn = sqlite3.connect(path)
            counts = {
                table: conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
                for table in (
                    "heart_rate_logs",
                    "baseline_heart_rate",
                    "abnormal_events",
                    "notifications",
                )
            }
            source, measurement_context = conn.execute(
                "SELECT source, measurement_context FROM heart_rate_logs"
            ).fetchone()
            conn.close()

            self.assertEqual(counts["heart_rate_logs"], 1)
            self.assertEqual(counts["baseline_heart_rate"], 0)
            self.assertEqual(counts["abnormal_events"], 0)
            self.assertEqual(counts["notifications"], 0)
            self.assertEqual(source, "POLAR_30S_AVERAGE")
            self.assertEqual(measurement_context, "general")
            self.assertIsNone(result["baseline"])
            self.assertIsNone(result["abnormal_event"])
            response = HeartRateResponse.model_validate(result)
            self.assertIsNone(response.baseline)
        finally:
            try:
                conn.close()
            except Exception:
                pass
            os.remove(path)

    def test_measurement_context_migration_is_additive_and_idempotent(self):
        handle, path = tempfile.mkstemp(suffix=".db")
        os.close(handle)
        try:
            conn = sqlite3.connect(path)
            conn.execute(
                """
                CREATE TABLE heart_rate_logs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id TEXT NOT NULL,
                    bpm INTEGER NOT NULL,
                    measured_at TEXT NOT NULL,
                    device_id TEXT,
                    source TEXT NOT NULL DEFAULT 'POLAR'
                )
                """
            )
            conn.execute(
                "INSERT INTO heart_rate_logs (user_id, bpm, measured_at, source) VALUES ('U1', 77, '2026-09-01T00:00:00', 'POLAR_30S_AVERAGE')"
            )
            init_db.ensure_additive_columns(conn.cursor())
            init_db.ensure_additive_columns(conn.cursor())
            row = conn.execute(
                "SELECT bpm, source, measurement_context FROM heart_rate_logs"
            ).fetchone()
            columns = {
                column[1]
                for column in conn.execute("PRAGMA table_info(heart_rate_logs)")
            }
            conn.close()
            self.assertIn("measurement_context", columns)
            self.assertEqual(row, (77, "POLAR_30S_AVERAGE", "general"))
        finally:
            try:
                conn.close()
            except Exception:
                pass
            os.remove(path)


if __name__ == "__main__":
    unittest.main()
