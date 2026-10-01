from pathlib import Path
import unittest


class HeartbeatWiringTest(unittest.TestCase):
    """새 심박 UI 구조와 Polar 운영·Dataset 정책을 함께 지킨다."""

    SENSOR = Path("lib/features/biosignal/application/heart_sensor.dart")
    POLAR = Path("lib/features/biosignal/data/polar_service.dart")
    MEASURE = Path(
        "lib/features/biosignal/presentation/screens/measure_screen.dart"
    )

    def test_operational_and_dataset_flows_remain_separate(self):
        source = self.SENSOR.read_text(encoding="utf-8")
        self.assertIn("_polar.currentBpmStream.listen", source)
        self.assertIn("_datasetCollector.addPolarBpm", source)
        self.assertIn("_polar.averageBpmStream.listen", source)
        self.assertIn("'/api/v1/biosignal/heart-rate'", source)
        self.assertIn("'source': 'POLAR_30S_AVERAGE'", source)
        self.assertIn("if (userId.isEmpty)", source)
        self.assertEqual(source.count("_polar.currentBpmStream.listen"), 1)
        self.assertEqual(source.count("_polar.averageBpmStream.listen"), 1)

    def test_new_route_and_screens_share_one_sensor(self):
        route_source = Path("lib/main.dart").read_text(encoding="utf-8")
        measure_source = self.MEASURE.read_text(encoding="utf-8")
        self.assertIn("builder: (context, state) => const HeartScreen()", route_source)
        self.assertIn("HeartSensor", measure_source)
        self.assertNotIn("_polar.startHrStreaming", measure_source)

    def test_baseline_then_average_policy_is_owned_by_sensor(self):
        sensor_source = self.SENSOR.read_text(encoding="utf-8")
        polar_source = self.POLAR.read_text(encoding="utf-8")
        self.assertIn("bpm == null || bpm <= 0", sensor_source)
        self.assertIn("Duration(seconds: 15)", sensor_source)
        self.assertIn("averageValidHeartRates(_baselineSamples)", sensor_source)
        self.assertIn("_polar.startAverageMonitoring()", sensor_source)
        self.assertIn("heartRateChangePercent(", sensor_source)
        self.assertIn("bool _isAverageMonitoring = false", polar_source)
        self.assertIn("Duration(seconds: 30)", polar_source)
        self.assertIn("if (_isAverageMonitoring)", polar_source)

    def test_permissions_are_checked_before_scan(self):
        source = self.SENSOR.read_text(encoding="utf-8")
        permission_check = source.index("permissionStatuses.values.any")
        device_scan = source.index("_polar.findDeviceId")
        self.assertLess(permission_check, device_scan)

    def test_no_baseline_ui_or_fixed_bpm_judgment(self):
        sensor_source = self.SENSOR.read_text(encoding="utf-8")
        measure_source = self.MEASURE.read_text(encoding="utf-8")
        self.assertNotIn("normalLow", sensor_source)
        self.assertNotIn("normalHigh", sensor_source)
        self.assertNotIn("기준 심박", measure_source)
        self.assertNotIn("30초 평균", measure_source)
        self.assertNotIn("정상 범위", measure_source)
        self.assertNotIn("HrAlertScreen", measure_source)


if __name__ == "__main__":
    unittest.main()
