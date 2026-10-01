import 'package:alkong_yakong/features/biosignal/data/polar_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('15초 baseline 평균은 유효 BPM만 사용한다', () {
    expect(averageValidHeartRates([60, 0, -1, 90]), 75);
    expect(averageValidHeartRates([0, -1]), isNull);
  });

  test('30초 평균 대비 변화율을 계산한다', () {
    expect(heartRateChangePercent(baseline: 80, currentAverage: 100), 25);
    expect(heartRateChangePercent(baseline: 100, currentAverage: 80), -20);
    expect(heartRateChangePercent(baseline: null, currentAverage: 80), isNull);
    expect(heartRateChangePercent(baseline: 0, currentAverage: 80), isNull);
  });
}
