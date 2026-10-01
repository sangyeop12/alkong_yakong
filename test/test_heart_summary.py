from datetime import datetime, timedelta
import unittest

from app.services.biosignal_service import (
    _best_streak,
    _pair_for_date,
    _streak,
)


class HeartPairingTest(unittest.TestCase):
    """사용자가 고른 측정 목적만 전·후로 맞춘다."""

    def setUp(self):
        self.taken_at = datetime(2026, 9, 10, 18, 0, 0)

    def test_picks_latest_reading_for_each_explicit_context(self):
        readings = [
            (self.taken_at - timedelta(minutes=60), 90, "before_medication"),
            (self.taken_at - timedelta(minutes=10), 78, "before_medication"),
            (self.taken_at + timedelta(minutes=12), 72, "after_medication"),
            (self.taken_at + timedelta(minutes=70), 68, "after_medication"),
        ]
        pair = _pair_for_date(readings)
        self.assertEqual(pair["before"], 78)
        self.assertEqual(pair["after"], 68)

    def test_general_readings_are_not_inferred_from_time(self):
        readings = [
            (self.taken_at - timedelta(minutes=5), 80, "general"),
            (self.taken_at + timedelta(minutes=5), 70, "general"),
        ]
        pair = _pair_for_date(readings)
        self.assertIsNone(pair["before"])
        self.assertIsNone(pair["after"])

    def test_missing_side_stays_none(self):
        """없는 값을 지어내지 않는다."""
        readings = [
            (self.taken_at + timedelta(minutes=5), 74, "after_medication")
        ]
        pair = _pair_for_date(readings)
        self.assertIsNone(pair["before"])
        self.assertEqual(pair["after"], 74)


class HeartMeasurementStreakTest(unittest.TestCase):
    def test_unmeasured_days_do_not_break_the_streak(self):
        """센서를 안 찬 날이 "이상한 날"이 되면 안 된다."""
        month = [
            {"day": 1, "after": 72},
            {"day": 2, "after": None},
            {"day": 3, "after": 70},
        ]
        self.assertEqual(_streak(month), 2)

    def test_bpm_value_does_not_create_a_medical_threshold(self):
        month = [
            {"day": 1, "after": 70},
            {"day": 2, "after": 96},
            {"day": 3, "after": 72},
        ]
        self.assertEqual(_streak(month), 3)
        self.assertEqual(_best_streak(month), 3)

    def test_best_streak_spans_the_whole_month(self):
        month = [
            {"day": 1, "after": 70},
            {"day": 2, "after": 71},
            {"day": 3, "after": 99},
            {"day": 4, "after": 72},
        ]
        self.assertEqual(_best_streak(month), 4)


if __name__ == "__main__":
    unittest.main()
