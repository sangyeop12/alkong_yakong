import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_config.dart';
import '../../../../core/session/mvp_session.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../medication/application/medication_controller.dart';
import '../../../medication/domain/medication_models.dart';
import '../widgets/day_dose_detail.dart';

/// 한 칸이 가질 수 있는 상태.
///
/// 칸 안에 복용 횟수를 적지 않는다 —
/// 숫자가 들어가면 한 달치를 한눈에 읽는 일이 다시 계산이 된다.
/// 약 일정이 없던 날은 [noRecord]다. 다 드신 날로 채우지 않는다.
enum DayMark { done, missed, today, future, noRecord }

/// 달력 한 칸.
@immutable
class CalendarDay {
  final int day;
  final DayMark mark;

  /// 그날 시간대별 결과. 칸을 누르면 아래 카드가 이것으로 바뀐다.
  final List<CalendarSlot> slots;

  const CalendarDay(this.day, this.mark, {this.slots = const []});
}

/// 그날 한 끼. 달력 칸에는 그리지 않고, 눌렀을 때만 쓴다.
@immutable
class CalendarSlot {
  /// "아침" / "점심" / "저녁"
  final String slot;
  final bool taken;

  const CalendarSlot({required this.slot, required this.taken});

  DoseSlot? get doseSlot => switch (slot) {
    '아침' => DoseSlot.morning,
    '점심' => DoseSlot.lunch,
    '저녁' => DoseSlot.dinner,
    _ => null,
  };
}

/// 빠뜨린 날 하나. 달력 아래에 **글로 다시** 적는다.
@immutable
class MissedDay {
  /// "8월 19일 수"
  final String label;

  /// "점심 약 한 번"
  final String detail;

  const MissedDay({required this.label, required this.detail});
}

/// 19 · 이번 달 달력.
///
/// 색은 세 가지뿐이다. 다 드신 날·빠뜨린 날·오늘.
/// 빠뜨린 날은 색만으로 끝내지 않고 아래에 글로 한 번 더 적는다 —
/// 색을 구분하기 어려운 눈에도 같은 사실이 남아야 한다.
class MonthCalendarScreen extends ConsumerStatefulWidget {
  final int? month;
  final int? year;
  final List<CalendarDay>? days;
  final int? leadingBlanks;
  final List<MissedDay>? missed;

  /// 보호자가 볼 어르신 id. null이면 로그인한 본인의 기록이다.
  final String? patientUserId;

  const MonthCalendarScreen({
    super.key,
    this.month,
    this.year,
    this.days,
    this.leadingBlanks,
    this.missed,
    this.patientUserId,
  });

  @override
  ConsumerState<MonthCalendarScreen> createState() =>
      _MonthCalendarScreenState();
}

class _MonthCalendarScreenState extends ConsumerState<MonthCalendarScreen> {
  static const List<String> _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

  late int _month;
  late int _year;
  late List<CalendarDay> _days;
  late int _leadingBlanks;
  late List<MissedDay> _missed;
  bool _hasSchedules = false;
  bool _loading = false;
  int? _pickedDay;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _year = widget.year ?? now.year;
    _month = widget.month ?? now.month;
    _days = widget.days ?? _emptyMonth(_year, _month);
    _leadingBlanks =
        widget.leadingBlanks ?? DateTime(_year, _month, 1).weekday - 1;
    if (_leadingBlanks < 0) _leadingBlanks = 6;
    _missed = widget.missed ?? const [];
    if (widget.days == null) {
      _loading = !_hasSchedules;
      _load();
    }
  }

  static List<CalendarDay> _emptyMonth(int year, int month) {
    final last = DateTime(year, month + 1, 0).day;
    final today = DateTime.now();
    return [
      for (int day = 1; day <= last; day++)
        CalendarDay(
          day,
          DateTime(year, month, day).year == today.year &&
                  DateTime(year, month, day).month == today.month &&
                  day == today.day
              ? DayMark.today
              : DayMark.future,
        ),
    ];
  }

  static DayMark _markOf(String raw) {
    return switch (raw) {
      'done' => DayMark.done,
      'missed' => DayMark.missed,
      'today' => DayMark.today,
      'noRecord' => DayMark.noRecord,
      _ => DayMark.future,
    };
  }

  static List<CalendarSlot> _slotsOf(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final row in raw)
        if (row is Map && (row['slot']?.toString() ?? '').isNotEmpty)
          CalendarSlot(
            slot: row['slot'].toString(),
            taken: row['taken'] == true,
          ),
    ];
  }

  Future<void> _load() async {
    try {
      final rawUserId = widget.patientUserId?.trim().isNotEmpty == true
          ? widget.patientUserId!.trim()
          : MvpSession.userId.trim();
      final userId = Uri.encodeComponent(rawUserId);
      final response = await ApiClient(baseUrl: ApiConfig.localFeatureBaseUrl)
          .get(
            '/api/v1/users/$userId/medication-calendar?year=$_year&month=$_month',
          );
      if (!mounted || response is! Map) {
        if (mounted) {
          setState(() => _loading = false);
        }
        return;
      }
      final daysRaw = response['days'];
      final missedRaw = response['missed'];
      setState(() {
        _month = (response['month'] as num?)?.toInt() ?? _month;
        _year = (response['year'] as num?)?.toInt() ?? _year;
        _leadingBlanks =
            (response['leading_blanks'] as num?)?.toInt() ?? _leadingBlanks;
        _hasSchedules = response['has_schedules'] == true;
        _days = daysRaw is List
            ? [
                for (final row in daysRaw)
                  if (row is Map)
                    CalendarDay(
                      (row['day'] as num?)?.toInt() ?? 0,
                      _markOf(row['mark']?.toString() ?? ''),
                      slots: _slotsOf(row['slots']),
                    ),
              ].where((item) => item.day > 0).toList()
            : _days;
        _missed = missedRaw is List
            ? [
                for (final row in missedRaw)
                  if (row is Map)
                    MissedDay(
                      label: row['label']?.toString() ?? '',
                      detail: row['detail']?.toString() ?? '',
                    ),
              ]
            : _missed;
        _loading = false;
      });
      if (mounted) setState(() {});
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      if (mounted) setState(() {});
    }
  }

  int get _doneCount => _days.where((d) => d.mark == DayMark.done).length;

  int get _scheduledPastCount => _days
      .where((d) => d.mark == DayMark.done || d.mark == DayMark.missed)
      .length;

  /// 아래 카드가 보여줄 날. 아무것도 안 눌렀으면 오늘이다.
  DateTime get _detailDate {
    final today = DateTime.now();
    final picked = _pickedDay;
    if (picked == null) return today;
    return DateTime(_year, _month, picked);
  }

  String get _detailLabel {
    final date = _detailDate;
    final today = DateTime.now();
    final isToday =
        date.year == today.year &&
        date.month == today.month &&
        date.day == today.day;
    return '${date.month}월 ${date.day}일${isToday ? ' 오늘' : ''}';
  }

  /// 오늘은 지금 받아 둔 복약 상태를, 다른 날은 달력이 받아 온 결과를 쓴다.
  List<DoseEntry> get _detailDoses {
    final date = _detailDate;
    final today = DateTime.now();
    final isToday =
        date.year == today.year &&
        date.month == today.month &&
        date.day == today.day;
    if (isToday && _pickedDay == null) {
      return ref.watch(medicationProvider).doses;
    }
    final match = _days.where((day) => day.day == date.day).toList();
    if (match.isEmpty) return const [];
    return [
      for (final slot in match.first.slots)
        if (slot.doseSlot != null)
          DoseEntry(
            slot: slot.doseSlot!,
            medicines: const [],
            taken: slot.taken,
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final cells = <CalendarDay?>[
      for (int i = 0; i < _leadingBlanks; i++) null,
      ..._days,
    ];
    final rowCount = (cells.length / 7).ceil();
    final summary = !_hasSchedules && _scheduledPastCount == 0
        ? '이달 복용 칸이 아직 없어요'
        : '$_scheduledPastCount일 중 $_doneCount일 다 드셨어요';

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          SeniorBackHeader(title: '$_month월 달력'),
          Expanded(
            child: _loading
                ? const Center(
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: CircularProgressIndicator(
                        strokeWidth: 4,
                        color: AppColors.point,
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SeniorCard(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              LabelValueRow(
                                label: Text(
                                  '$_month월',
                                  style: AppText.cardTitle(size: 21),
                                ),
                                value: Text(
                                  summary,
                                  style: AppText.label(
                                    size: 17.5,
                                    color: AppColors.textTertiary,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  for (final weekday in _weekdays)
                                    Expanded(
                                      child: Text(
                                        weekday,
                                        textAlign: TextAlign.center,
                                        style: AppText.cardTitle(
                                          size: 16,
                                          color: AppColors.textTertiary,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              for (int row = 0; row < rowCount; row++) ...[
                                if (row > 0) const SizedBox(height: 6),
                                IntrinsicHeight(
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      for (int col = 0; col < 7; col++) ...[
                                        if (col > 0) const SizedBox(width: 6),
                                        Expanded(
                                          child:
                                              row * 7 + col < cells.length &&
                                                  cells[row * 7 + col] != null
                                              ? _DayCell(
                                                  cells[row * 7 + col]!,
                                                  picked:
                                                      cells[row * 7 + col]!
                                                          .day ==
                                                      _pickedDay,
                                                  onTap: () => setState(
                                                    () => _pickedDay =
                                                        cells[row * 7 + col]!
                                                            .day,
                                                  ),
                                                )
                                              : const SizedBox.shrink(),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                              const SizedBox(height: 16),
                              const _Legend(),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        // 기록 탭과 같은 하루 상세를 둔다. 두 화면이 서로 다른
                        // 모양으로 같은 내용을 말하면 다른 것으로 읽힌다.
                        DayDoseDetail(
                          dayLabel: _detailLabel,
                          date: _detailDate,
                          doses: _detailDoses,
                          footnote: null,
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  final CalendarDay day;
  final bool picked;
  final VoidCallback? onTap;

  const _DayCell(this.day, {this.picked = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    late final Color background;
    late final Color ink;
    late final String mark;
    late final String spoken;
    BoxBorder? border;

    switch (day.mark) {
      case DayMark.done:
        // 옅은 톤은 회색으로 읽힌다. 다 드신 날은 한눈에 파랗게 보여야 한다.
        background = AppColors.timelineRing;
        ink = AppColors.pointBorder;
        mark = '✓';
        spoken = '다 드신 날';
      case DayMark.missed:
        background = AppColors.dangerBg;
        ink = AppColors.danger;
        border = Border.all(color: AppColors.danger, width: 2);
        mark = '✕';
        spoken = '빠뜨린 날';
      case DayMark.today:
        background = AppColors.point;
        ink = Colors.white;
        border = Border.all(color: AppColors.pointBorder, width: 2);
        mark = '오늘';
        spoken = '오늘';
      case DayMark.future:
        background = AppColors.sunken;
        ink = AppColors.inactive;
        mark = '·';
        spoken = '아직 오지 않은 날';
      case DayMark.noRecord:
        background = AppColors.sunken;
        ink = AppColors.inactive;
        mark = '-';
        spoken = '기록 없는 날';
    }

    // 누른 칸은 파란 테두리로 표시한다. 색만 바꾸면 어떤 날을 보고 있는지
    // 아래 카드와 이어지지 않는다.
    if (picked) {
      border = Border.all(color: AppColors.point, width: 3);
    }

    return Semantics(
      label: '${day.day}일 $spoken',
      button: onTap != null,
      child: GestureDetector(
        onTap: onTap,
        child: ExcludeSemantics(
          child: Container(
            constraints: const BoxConstraints(minHeight: 54),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(14),
              border: border,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${day.day}',
                  style: AppText.cardTitle(
                    size: 18,
                    color: ink,
                  ).copyWith(height: 1),
                ),
                const SizedBox(height: 2),
                Text(
                  mark,
                  textAlign: TextAlign.center,
                  style: AppText.cardTitle(
                    size: 15,
                    color: ink,
                  ).copyWith(height: 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 14,
      runSpacing: 10,
      children: [
        _LegendItem(
          color: AppColors.timelineRing,
          border: null,
          label: '다 드신 날',
        ),
        _LegendItem(
          color: AppColors.dangerBg,
          border: Border.all(color: AppColors.danger, width: 2),
          label: '빠뜨린 날',
        ),
        _LegendItem(
          color: AppColors.point,
          border: Border.all(color: AppColors.pointBorder, width: 2),
          label: '오늘',
        ),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final BoxBorder? border;
  final String label;

  const _LegendItem({
    required this.color,
    required this.border,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(6),
            border: border,
          ),
        ),
        const SizedBox(width: 7),
        Text(
          label,
          style: AppText.label(size: 16.5, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}
