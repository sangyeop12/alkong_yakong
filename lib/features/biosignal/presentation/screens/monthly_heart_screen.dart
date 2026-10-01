import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_feedback.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../domain/heart_data.dart';
import '../widgets/heart_readings_card.dart';

/// 26 · 한 달 기록.
///
/// 명시적으로 복약 전·후라고 저장된 기록만 비교한다. 일반 측정이나
/// 측정 시각으로 전·후를 추정하지 않는다.
///
/// [data]는 심박수 관리 화면이 서버에서 읽어 넘겨준 것만 받는다.
/// 잰 날이 하나도 없으면 "0일째 정상"을 그리지 않고 기록이 없다고 말한다.
class MonthlyHeartScreen extends StatefulWidget {
  final HeartData data;
  final String guardianTitle;

  /// 날짜에 붙일 "몇 월". 서버는 이번 달 날짜만 보내므로 기본은 오늘이다.
  /// 테스트에서 날짜를 고정할 때만 넘긴다.
  final DateTime? now;

  const MonthlyHeartScreen({
    super.key,
    required this.data,
    this.guardianTitle = '',
    this.now,
  });

  @override
  State<MonthlyHeartScreen> createState() => _MonthlyHeartScreenState();
}

class _MonthlyHeartScreenState extends State<MonthlyHeartScreen> {
  late final int _month = (widget.now ?? DateTime.now()).month;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final readings = data.readingsFor(monthly: true);
    final comparison = _MonthlyComparison.fromReadings(readings);
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          SeniorHeader(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const SeniorBackButton(),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        '한 달 기록',
                        style: AppText.screenTitle(size: 24),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SeniorSegmented(
                  labels: const ['이번 주', '한 달'],
                  index: 1,
                  onChanged: (i) {
                    if (i == 0) Navigator.of(context).maybePop();
                  },
                ),
              ],
            ),
          ),
          Expanded(
            // 헤더와 탭 아래의 별도 viewport로 제한해 기록이 상단 영역
            // 뒤에 그려지지 않게 한다.
            child: ClipRect(
              child: SingleChildScrollView(
                key: const Key('monthly-heart-scroll'),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (readings.isEmpty)
                      _EmptyMonthCard(month: _month)
                    else ...[
                      HeartReadingsCard(
                        readings: readings,
                        hasComparison: comparison.pairCount > 0,
                      ),
                      const SizedBox(height: 12),
                      _MonthSummaryCard(month: _month, comparison: comparison),
                      if (comparison.weeks.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _WeeklyBars(weeks: comparison.weeks),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 이번 달에 잰 날이 하나도 없을 때.
class _EmptyMonthCard extends StatelessWidget {
  final int month;
  const _EmptyMonthCard({required this.month});

  @override
  Widget build(BuildContext context) {
    return SeniorCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        children: [
          const ExcludeSemantics(
            child: Icon(
              TablerIcons.calendar_off,
              size: 40,
              color: AppColors.textTertiary,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '$month월에는 아직 측정 기록이 없어요',
            textAlign: TextAlign.center,
            style: AppText.cardTitle(size: 21),
          ),
          const SizedBox(height: 6),
          Text(
            '약 먹기 전·후로 재면 날짜별로 여기에 모여요.',
            textAlign: TextAlign.center,
            style: AppText.body(size: 18, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _MonthSummaryCard extends StatelessWidget {
  final int month;
  final _MonthlyComparison comparison;

  const _MonthSummaryCard({required this.month, required this.comparison});

  @override
  Widget build(BuildContext context) {
    if (comparison.pairCount == 0) {
      return SeniorCard(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('복약 전·후 비교', style: AppText.cardTitle(size: 20)),
            const SizedBox(height: 8),
            Text(
              '복약 전·후를 비교할 기록이 아직 부족해요.',
              style: AppText.body(size: 18, color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      decoration: BoxDecoration(
        color: AppColors.point,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$month월 한 달',
            style: AppText.label(size: 17.5, color: AppColors.onPointMuted),
          ),
          const SizedBox(height: 6),
          Text(
            '복약 후 평균 심박수가',
            style: AppText.cardTitle(size: 20, color: Colors.white),
          ),
          const SizedBox(height: 2),
          Text(
            comparison.changeSummary,
            style: AppText.hero(size: 34, color: Colors.white),
          ),
          const SizedBox(height: 14),
          _AverageRangeRow(label: '복약 전', value: comparison.beforeAverage),
          const SizedBox(height: 8),
          _AverageRangeRow(
            label: '복약 후',
            value: comparison.afterAverage,
            emphasize: true,
          ),
          const SizedBox(height: 14),
          Container(height: 1, color: Colors.white.withValues(alpha: 0.22)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '비교 기록 ${comparison.weeks.length}주',
                  style: AppText.label(size: 16, color: Colors.white),
                ),
              ),
              Text(
                comparison.weeks.length == 1
                    ? '아직 경향을 판단하기 어려워요'
                    : '여러 주의 변화를 함께 확인해 보세요',
                style: AppText.body(size: 16, color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '성인 안정 시 기준을 참고한 안내예요.\n약의 영향으로 단정할 수 없어요.',
            style: AppText.body(size: 16, color: AppColors.onPointMuted),
          ),
        ],
      ),
    );
  }
}

class _AverageRangeRow extends StatelessWidget {
  final String label;
  final int value;
  final bool emphasize;

  const _AverageRangeRow({
    required this.label,
    required this.value,
    this.emphasize = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '$label  $value회/분',
            style: AppText.label(
              size: 18,
              color: emphasize ? AppColors.point : AppColors.textPrimary,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: emphasize ? AppColors.pointTint : AppColors.sunken,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              _heartRateRange(value),
              style: AppText.caption(
                size: 16,
                color: emphasize ? AppColors.point : AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 비교 가능한 주가 하나라도 있으면 전·후 평균을 나란히 보여준다.
class _WeeklyBars extends StatelessWidget {
  final List<_WeekAverage> weeks;

  const _WeeklyBars({required this.weeks});

  @override
  Widget build(BuildContext context) {
    final highest = weeks
        .expand((week) => [week.before, week.after])
        .reduce((a, b) => a > b ? a : b);

    return SeniorCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('주별 평균', style: AppText.cardTitle()),
          const SizedBox(height: 6),
          Text(
            '단위: 회/분 · 비교 가능한 주 ${weeks.length}주',
            style: AppText.caption(size: 16),
          ),
          const SizedBox(height: 10),
          const _BarLegend(),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final itemWidth = weeks.length <= 2
                  ? constraints.maxWidth / weeks.length
                  : 112.0;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final week in weeks)
                        SizedBox(
                          width: itemWidth,
                          child: _WeekPair(week: week, highest: highest),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 한 주의 전·후 평균.
class _WeekAverage {
  final DateTime start;
  final int before;
  final int after;

  const _WeekAverage({
    required this.start,
    required this.before,
    required this.after,
  });

  DateTime get end => start.add(const Duration(days: 6));

  String get periodLabel =>
      '${start.month}/${start.day}~${end.month}/${end.day}';
}

/// 한 주의 막대 두 개 — 왼쪽이 먹기 전, 오른쪽이 먹은 뒤.
class _WeekPair extends StatelessWidget {
  final _WeekAverage week;
  final int highest;

  const _WeekPair({required this.week, required this.highest});

  double _height(int value) {
    if (highest == 0) return 0;
    return 24 + (value / highest) * 84;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 160,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text('${week.before}', style: AppText.label(size: 16)),
                  const SizedBox(height: 3),
                  _Bar(
                    height: _height(week.before),
                    color: AppColors.secondaryFill,
                  ),
                ],
              ),
              const SizedBox(width: 5),
              Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    '${week.after}',
                    key: const Key('weekly-after-value'),
                    style: AppText.label(size: 16, color: AppColors.point),
                  ),
                  const SizedBox(height: 3),
                  _Bar(height: _height(week.after), color: AppColors.point),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          week.periodLabel,
          textAlign: TextAlign.center,
          style: AppText.caption(size: 15),
        ),
        const SizedBox(height: 3),
        Text.rich(
          key: const Key('weekly-values-label'),
          TextSpan(
            children: [
              TextSpan(text: '전 ${week.before} · '),
              TextSpan(
                text: '후 ${week.after}',
                style: const TextStyle(color: AppColors.point),
              ),
            ],
          ),
          textAlign: TextAlign.center,
          style: AppText.caption(size: 15, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  final double height;
  final Color color;

  const _Bar({required this.height, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(5),
      ),
    );
  }
}

/// 막대 두 색이 무엇인지 알려 주는 표시.
class _BarLegend extends StatelessWidget {
  const _BarLegend();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: const [
        _LegendDot(color: AppColors.secondaryFill, label: '복약 전 평균'),
        _LegendDot(color: AppColors.point, label: '복약 후 평균'),
      ],
    );
  }
}

class _MonthlyComparison {
  final List<_DailyPair> pairs;
  final List<_WeekAverage> weeks;

  const _MonthlyComparison({required this.pairs, required this.weeks});

  int get pairCount => pairs.length;

  int get beforeAverage => _average(pairs.map((pair) => pair.before));
  int get afterAverage => _average(pairs.map((pair) => pair.after));

  String get changeSummary {
    final difference = afterAverage - beforeAverage;
    if (difference > 0) return '$difference회/분 높았어요';
    if (difference < 0) return '${difference.abs()}회/분 낮았어요';
    return '복약 전과 같았어요';
  }

  static _MonthlyComparison fromReadings(List<HeartReading> readings) {
    final days = <int, _DayMeasurements>{};
    for (final reading in readings) {
      if (reading.measurementContext == HeartMeasurementContext.general) {
        continue;
      }
      final at = reading.measuredAt.toLocal();
      final date = DateTime(at.year, at.month, at.day);
      final key = at.year * 10000 + at.month * 100 + at.day;
      final values = days.putIfAbsent(key, () => _DayMeasurements(date));
      if (reading.measurementContext ==
          HeartMeasurementContext.beforeMedication) {
        values.before.add(reading.bpm);
      } else if (reading.measurementContext ==
          HeartMeasurementContext.afterMedication) {
        values.after.add(reading.bpm);
      }
    }

    final pairs = <_DailyPair>[
      for (final values in days.values)
        if (values.before.isNotEmpty && values.after.isNotEmpty)
          _DailyPair(
            date: values.date,
            before: _average(values.before),
            after: _average(values.after),
          ),
    ]..sort((a, b) => a.date.compareTo(b.date));

    final groupedWeeks = <DateTime, List<_DailyPair>>{};
    for (final pair in pairs) {
      final start = pair.date.subtract(Duration(days: pair.date.weekday - 1));
      groupedWeeks.putIfAbsent(start, () => <_DailyPair>[]).add(pair);
    }
    final weeks = <_WeekAverage>[
      for (final entry in groupedWeeks.entries)
        _WeekAverage(
          start: entry.key,
          before: _average(entry.value.map((pair) => pair.before)),
          after: _average(entry.value.map((pair) => pair.after)),
        ),
    ]..sort((a, b) => a.start.compareTo(b.start));

    return _MonthlyComparison(pairs: pairs, weeks: weeks);
  }
}

class _DayMeasurements {
  final DateTime date;
  final List<int> before = <int>[];
  final List<int> after = <int>[];

  _DayMeasurements(this.date);
}

class _DailyPair {
  final DateTime date;
  final int before;
  final int after;

  const _DailyPair({
    required this.date,
    required this.before,
    required this.after,
  });
}

int _average(Iterable<int> values) {
  final list = values.toList();
  if (list.isEmpty) {
    throw StateError('Cannot average an empty heart-rate set.');
  }
  return (list.reduce((a, b) => a + b) / list.length).round();
}

String _heartRateRange(int bpm) {
  if (bpm < 60) return '느린 범위';
  if (bpm <= 100) return '일반 범위';
  return '빠른 범위';
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(label, style: AppText.caption(size: 16)),
      ],
    );
  }
}
