import sqlite3
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

import init_db
from fastapi import FastAPI
from fastapi.testclient import TestClient
from app.models.schemas import HeartRateCreate
from app.routes.biosignal import router
from app.services import biosignal_service as service


class HeartReadingsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = str(Path(self.temp.name) / 'records.db')
        with patch.object(init_db, 'DB_PATH', self.path):
            init_db.initialize_database()
        with self.connection() as conn:
            conn.executemany('INSERT INTO users (id, name, role) VALUES (?, ?, ?)',
                             [('test-a', 'synthetic', 'PATIENT'), ('test-b', 'synthetic', 'PATIENT')])
        self.patch = patch.object(service, 'get_connection', self.connection)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def connection(self):
        # TestClient dispatches synchronous routes on its worker thread.
        conn = sqlite3.connect(self.path, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        self.addCleanup(conn.close)
        return conn

    def save(self, at, bpm=98, user='test-a', context='general'):
        return service.save_heart_rate(HeartRateCreate(user_id=user, bpm=bpm,
            measured_at=at, source='POLAR_30S_AVERAGE', measurement_context=context))

    def summary(self, now='2026-09-18T06:00:00Z'):
        return service.get_heart_summary('test-a', datetime.fromisoformat(now.replace('Z', '+00:00')),
                                        include_readings=True, utc_offset_minutes=540)

    def test_standalone_saved_visible_without_medication_and_no_read_side_writes(self):
        saved = self.save('2026-09-18T05:42:00Z')
        data = self.summary()
        self.assertEqual(data['readings'], [{'id': saved['heart_rate_log_id'], 'bpm': 98,
                                             'measured_at': '2026-09-18T14:42:00+09:00',
                                             'measurement_context': 'general'}])
        self.assertEqual(data['today'], {'before': None, 'after': None})
        self.assertTrue(all(d['before'] is None and d['after'] is None for d in data['week'] + data['month']))
        self.summary()
        with self.connection() as conn:
            self.assertEqual(conn.execute('SELECT COUNT(*) FROM heart_rate_logs').fetchone()[0], 1)
            self.assertEqual(conn.execute('SELECT COUNT(*) FROM medication_logs').fetchone()[0], 0)

    def test_user_isolation_and_offset_preserved(self):
        self.save('2026-09-18T14:42:00+09:00')
        self.save('2026-09-18T14:43:00+09:00', user='test-b', bpm=77)
        self.assertEqual(len(self.summary()['readings']), 1)
        saved = self.save('2026-09-18T14:42:00+09:00')
        self.assertEqual(datetime.fromisoformat(saved['measured_at']), datetime(2026, 9, 18, 5, 42, tzinfo=timezone.utc))

    def test_month_midnight_boundary_and_previous_week(self):
        self.save('2026-08-31T14:59:00Z', 70)
        self.save('2026-08-31T15:00:00Z', 71)
        data = self.summary('2026-08-31T15:10:00Z')
        self.assertEqual(data['period_date'], '2026-09-01')
        # Monday August 31 remains in the week; September 1 begins the month.
        self.assertEqual([r['bpm'] for r in data['readings']], [71, 70])
        self.assertEqual(data['readings'][0]['measured_at'], '2026-09-01T00:00:00+09:00')

    def test_week_boundary_excludes_previous_sunday_outside_month(self):
        self.save('2026-05-31T14:59:00Z', 70)
        self.save('2026-05-31T15:00:00Z', 71)
        data = self.summary('2026-05-31T15:10:00Z')
        self.assertEqual(data['period_date'], '2026-06-01')
        self.assertEqual([r['bpm'] for r in data['readings']], [71])

    def test_legacy_contract_unchanged_and_comparison_not_duplicated(self):
        self.save('2026-09-18T05:00:00Z', 90, context='before_medication')
        self.save('2026-09-18T06:00:00Z', 98, context='after_medication')
        with self.connection() as conn:
            conn.execute("INSERT INTO medication_logs (user_id, taken_at, status) VALUES (?, ?, ?)",
                         ('test-a', '2026-09-18 05:30:00', 'TAKEN'))
        data = self.summary()
        self.assertEqual(data['today'], {'before': 90, 'after': 98})
        self.assertEqual(data['before_at'], '14:00')
        self.assertEqual(len(data['readings']), 2)
        legacy = service.get_heart_summary('test-a', datetime(2026, 9, 18, 7))
        self.assertNotIn('readings', legacy)
        self.assertEqual(legacy['today'], data['today'])
        self.assertEqual(legacy['before_at'], '05:00')

    def test_general_measurements_are_not_inferred_as_medication_pairs(self):
        self.save('2026-09-18T05:00:00Z', 90)
        self.save('2026-09-18T06:00:00Z', 98)
        with self.connection() as conn:
            conn.execute("INSERT INTO medication_logs (user_id, taken_at, status) VALUES (?, ?, ?)",
                         ('test-a', '2026-09-18 05:30:00', 'TAKEN'))
        data = self.summary()
        self.assertEqual(data['today'], {'before': None, 'after': None})
        self.assertEqual(len(data['readings']), 2)

    def test_context_default_allowed_values_and_unknown_rejection(self):
        saved = self.save('2026-09-18T05:00:00Z')
        self.assertEqual(saved['measurement_context'], 'general')
        for context in ('general', 'before_medication', 'after_medication'):
            self.assertEqual(
                HeartRateCreate(user_id='test-a', bpm=70,
                                measurement_context=context).measurement_context,
                context,
            )
        with self.assertRaises(ValueError):
            HeartRateCreate(user_id='test-a', bpm=70,
                            measurement_context='invalid')

    def test_naive_server_time_gets_zone_without_changing_stored_value(self):
        raw = '2026-09-18T05:42:00'
        saved = self.save(raw)
        self.assertIsNotNone(datetime.fromisoformat(saved['measured_at']).tzinfo)
        self.assertEqual(datetime.fromisoformat(saved['measured_at']), datetime.fromisoformat(raw).astimezone(timezone.utc))
        with self.connection() as conn:
            self.assertEqual(conn.execute('SELECT measured_at FROM heart_rate_logs').fetchone()[0], raw)

    def test_route_opt_in_compatibility_and_invalid_offset(self):
        app = FastAPI()
        app.include_router(router)
        with TestClient(app) as client:
            old = client.get('/api/v1/users/test-a/biosignal/heart-summary')
            self.assertEqual(old.status_code, 200)
            self.assertNotIn('readings', old.json())
            new = client.get('/api/v1/users/test-a/biosignal/heart-summary',
                             params={'include_readings': True, 'utc_offset_minutes': 540})
            self.assertEqual(new.status_code, 200)
            self.assertEqual(new.json()['readings'], [])
            self.assertEqual(client.get('/api/v1/users/test-a/biosignal/heart-summary',
                             params={'utc_offset_minutes': 1440}).status_code, 422)
            self.assertEqual(client.get('/api/v1/users/missing/biosignal/heart-summary').status_code, 404)


if __name__ == '__main__':
    unittest.main()
