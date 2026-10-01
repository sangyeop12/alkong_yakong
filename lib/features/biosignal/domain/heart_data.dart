import 'package:flutter/foundation.dart';

enum HeartMeasurementContext {
  general('general', '평소 심박 측정'),
  beforeMedication('before_medication', '복약 전 측정'),
  afterMedication('after_medication', '복약 후 측정');

  const HeartMeasurementContext(this.value, this.label);
  final String value;
  final String label;

  static HeartMeasurementContext fromValue(Object? value) => values.firstWhere(
    (context) => context.value == value,
    orElse: () => general,
  );
}

/// One stored measurement, independent of medication comparison pairs.
@immutable
class HeartReading {
  final int id;
  final int bpm;
  final DateTime measuredAt;
  final HeartMeasurementContext measurementContext;
  const HeartReading({
    required this.id,
    required this.bpm,
    required this.measuredAt,
    this.measurementContext = HeartMeasurementContext.general,
  });
}

/// 복약 **전·후 한 쌍**의 심박수.
///
/// 사용자가 복약 전·후로 목적을 표시한 기록만 이 비교 자료에 들어간다.
/// 일반 측정은 시각만으로 전·후를 추정하지 않는다.
@immutable
class HeartPair {
  /// 약 먹기 전 수치. 재지 못했으면 null.
  final int? before;

  /// 약 먹은 뒤 수치. 아직 안 쟀으면 null.
  final int? after;

  const HeartPair({this.before, this.after});

  bool get isComplete => before != null && after != null;

  /// 먹은 뒤 몇 회 낮아졌는지. 올라갔으면 음수.
  int? get drop => isComplete ? before! - after! : null;
}

/// 이번 주 한 칸 — 요일 하나의 전·후 쌍.
@immutable
class HeartDay {
  /// "월", "화" …
  final String weekday;
  final HeartPair pair;

  const HeartDay(this.weekday, this.pair);
}

/// 한 달 기록의 하루.
@immutable
class HeartMonthDay {
  final int day;
  final HeartPair pair;

  const HeartMonthDay(this.day, this.pair);

  /// 재지 못한 날.
  bool get isMissing => pair.after == null;
}

/// 심박수 화면 전체가 쓰는 데이터 묶음.
///
/// `/api/v1/users/{id}/biosignal/heart-summary` 응답을 `HeartRepository`가
/// 이 모양으로 옮긴다. 화면은 **읽어 온 값만** 그린다 — 못 읽었으면
/// 불러오는 중·못 불러옴·기록 없음을 그대로 말한다.
@immutable
class HeartData {
  final List<HeartReading> readings;
  final DateTime? periodDate;

  List<HeartReading> readingsFor({required bool monthly}) {
    final now = periodDate ?? DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    final start = monthly
        ? DateTime(day.year, day.month)
        : DateTime(day.year, day.month, day.day - day.weekday + 1);
    final end = DateTime(day.year, day.month, day.day + 1);
    return readings.where((r) {
      final at = r.measuredAt.toLocal();
      return !at.isBefore(start) && at.isBefore(end);
    }).toList();
  }

  /// 서버가 정한 조회 기준일의 현지 날짜에 저장된 실제 측정 기록.
  ///
  /// 복약 전·후 요약과 별개로 `general` 기록도 오늘 카드에 보여 주기 위해
  /// 원시 기록에서 고른다. 시각으로 측정 목적을 추정하지 않는다.
  List<HeartReading> get todayReadings {
    final now = periodDate ?? DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end = start.add(const Duration(days: 1));
    return readings.where((reading) {
      final at = reading.measuredAt.toLocal();
      return !at.isBefore(start) && at.isBefore(end);
    }).toList()..sort((a, b) => b.measuredAt.compareTo(a.measuredAt));
  }

  /// 오늘 잰 것.
  final HeartPair today;

  /// 오늘 어느 때 약인지. "저녁 약".
  final String todaySlotLabel;

  /// 전·후를 잰 시각.
  final String beforeAt;
  final String afterAt;

  /// 이번 주 7일.
  final List<HeartDay> week;

  /// 이번 달 날짜별.
  final List<HeartMonthDay> month;

  /// 심박수가 계속 정상인 연속 일수와 최고 기록.
  final int streakDays;
  final int bestStreakDays;

  /// 이상이 있었던 날 (없으면 null).
  final HeartAnomaly? anomaly;

  /// 센서 상태.
  final bool sensorConnected;

  /// 남은 배터리 (0~100). 기기가 아직 안 알려줬으면 null.
  /// **0으로 두지 않는다** — 0%는 "다 닳았다"는 뜻이라 모른다는 것과 다르다.
  final int? sensorBattery;
  final String sensorLastReadAt;

  /// 심박수가 빠르면 보호자에게 자동으로 알릴지.
  final bool notifyGuardian;

  const HeartData({
    this.readings = const [],
    this.periodDate,
    required this.today,
    required this.todaySlotLabel,
    required this.beforeAt,
    required this.afterAt,
    required this.week,
    required this.month,
    required this.streakDays,
    required this.bestStreakDays,
    required this.anomaly,
    required this.sensorConnected,
    required this.sensorBattery,
    required this.sensorLastReadAt,
    required this.notifyGuardian,
  });

  /// 이번 주 모든 날이 약을 드신 뒤 낮아졌는지.
  bool get allDropped => week.every((d) => (d.pair.drop ?? 0) > 0);

  /// 오늘·이번 주·이번 달 중 한 번이라도 잰 값이 있는지.
  ///
  /// 서버는 기록이 없어도 빈 칸 7개·날짜 칸 N개를 채워 보낸다.
  /// 칸이 있다고 기록이 있는 것은 아니므로 값으로 판단한다.
  bool get hasReadings {
    bool has(HeartPair p) => p.before != null || p.after != null;
    return readings.isNotEmpty ||
        has(today) ||
        week.any((d) => has(d.pair)) ||
        month.any((d) => has(d.pair));
  }

  HeartData copyWith({
    bool? sensorConnected,
    bool? notifyGuardian,
    HeartPair? today,
    int? sensorBattery,
  }) => HeartData(
    readings: readings,
    periodDate: periodDate,
    today: today ?? this.today,
    todaySlotLabel: todaySlotLabel,
    beforeAt: beforeAt,
    afterAt: afterAt,
    week: week,
    month: month,
    streakDays: streakDays,
    bestStreakDays: bestStreakDays,
    anomaly: anomaly,
    sensorConnected: sensorConnected ?? this.sensorConnected,
    sensorBattery: sensorBattery ?? this.sensorBattery,
    sensorLastReadAt: sensorLastReadAt,
    notifyGuardian: notifyGuardian ?? this.notifyGuardian,
  );

  /// 핸드오프 05-CONTENT-RULES §4의 데모 데이터.
  static const HeartData demo = HeartData(
    today: HeartPair(before: 78, after: 72),
    todaySlotLabel: '저녁 약',
    beforeAt: '오후 5시 52분',
    afterAt: '오후 6시 40분',
    week: [
      HeartDay('월', HeartPair(before: 80, after: 74)),
      HeartDay('화', HeartPair(before: 78, after: 71)),
      HeartDay('수', HeartPair(before: 82, after: 76)),
      HeartDay('목', HeartPair(before: 77, after: 70)),
      HeartDay('금', HeartPair(before: 84, after: 79)),
      HeartDay('토', HeartPair(before: 76, after: 70)),
      HeartDay('일', HeartPair(before: 78, after: 72)),
    ],
    month: [
      HeartMonthDay(1, HeartPair(before: 79, after: 73)),
      HeartMonthDay(2, HeartPair(before: 77, after: 71)),
      HeartMonthDay(3, HeartPair(before: 81, after: 75)),
      HeartMonthDay(4, HeartPair(before: 78, after: 72)),
      HeartMonthDay(5, HeartPair(before: 76, after: 70)),
      HeartMonthDay(6, HeartPair(before: 80, after: 74)),
      HeartMonthDay(7, HeartPair(before: 79, after: 73)),
      HeartMonthDay(8, HeartPair(before: 77, after: 72)),
      HeartMonthDay(9, HeartPair()),
      HeartMonthDay(10, HeartPair(before: 78, after: 71)),
      HeartMonthDay(11, HeartPair(before: 82, after: 76)),
      HeartMonthDay(12, HeartPair(before: 96, after: 84)),
      HeartMonthDay(13, HeartPair(before: 80, after: 74)),
      HeartMonthDay(14, HeartPair(before: 77, after: 70)),
      HeartMonthDay(15, HeartPair(before: 79, after: 73)),
      HeartMonthDay(16, HeartPair(before: 78, after: 72)),
      HeartMonthDay(17, HeartPair(before: 81, after: 75)),
      HeartMonthDay(18, HeartPair(before: 76, after: 71)),
      HeartMonthDay(19, HeartPair(before: 80, after: 74)),
      HeartMonthDay(20, HeartPair(before: 78, after: 73)),
      HeartMonthDay(21, HeartPair(before: 78, after: 72)),
    ],
    streakDays: 9,
    bestStreakDays: 14,
    anomaly: HeartAnomaly(day: 12, slotLabel: '저녁', before: 96, after: 84),
    sensorConnected: true,
    sensorBattery: 82,
    sensorLastReadAt: '오후 6시 40분',
    notifyGuardian: true,
  );
}

/// 한 달 안에서 한 번 빠르게 뛴 날.
@immutable
class HeartAnomaly {
  final int day;
  final String slotLabel;
  final int before;
  final int after;

  const HeartAnomaly({
    required this.day,
    required this.slotLabel,
    required this.before,
    required this.after,
  });
}
