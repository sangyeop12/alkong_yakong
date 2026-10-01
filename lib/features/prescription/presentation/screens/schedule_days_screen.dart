import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_config.dart';
import '../../../../core/session/mvp_session.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_feedback.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../dashboard/application/medication_history_provider.dart';
import '../../../medication/application/medication_controller.dart';
import '../../../medicines/application/user_medicines_controller.dart';

/// 이번에 등록한 약의 한 칸. 먹었어요/빠뜨렸어요가 아니다.
@immutable
class ScheduleDayCell {
  final int day;
  final bool on;
  final bool isToday;

  const ScheduleDayCell({
    required this.day,
    required this.on,
    this.isToday = false,
  });
}

/// 등록 직후 · 약 있는 날을 확인하고 고치는 달력.
///
/// 기록 달력과 색·말이 다르다. 칸 안에 횟수 숫자를 적지 않는다.
class ScheduleDaysScreen extends ConsumerStatefulWidget {
  final String? prescriptionId;
  final VoidCallback? onConfirmed;
  final int? year;
  final int? month;
  final List<ScheduleDayCell>? days;
  final int? leadingBlanks;
  final String? headline;

  const ScheduleDaysScreen({
    super.key,
    this.prescriptionId,
    this.onConfirmed,
    this.year,
    this.month,
    this.days,
    this.leadingBlanks,
    this.headline,
  });

  @override
  ConsumerState<ScheduleDaysScreen> createState() => _ScheduleDaysScreenState();
}

class _ScheduleDaysScreenState extends ConsumerState<ScheduleDaysScreen> {
  static const List<String> _weekdays = ['월', '화', '수', '목', '금', '토', '일'];
  final ApiClient _localApi = ApiClient(baseUrl: ApiConfig.localFeatureBaseUrl);

  late int _year;
  late int _month;
  late List<ScheduleDayCell> _days;
  late int _leadingBlanks;
  late String _headline;
  bool _hasTimes = true;
  bool _loading = false;
  bool _saving = false;
  int? _busyDay;

  String get _prescriptionId {
    final fromWidget = widget.prescriptionId?.trim() ?? '';
    if (fromWidget.isNotEmpty) return fromWidget;
    return MvpSession.latestPrescriptionId?.trim() ?? '';
  }

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
    _headline = widget.headline ?? '투약일수를 확인해 주세요';
    if (widget.days == null) {
      _loading = true;
      _load();
    }
  }

  static List<ScheduleDayCell> _emptyMonth(int year, int month) {
    final last = DateTime(year, month + 1, 0).day;
    final today = DateTime.now();
    return [
      for (int day = 1; day <= last; day++)
        ScheduleDayCell(
          day: day,
          on: false,
          isToday:
              today.year == year && today.month == month && today.day == day,
        ),
    ];
  }

  Future<void> _load() async {
    final prescriptionId = _prescriptionId;
    final widgetPrescriptionId = widget.prescriptionId?.trim() ?? '';
    final sessionPrescriptionId = MvpSession.latestPrescriptionId?.trim() ?? '';
    final prescriptionIdSource = widgetPrescriptionId.isNotEmpty
        ? 'widget'
        : sessionPrescriptionId.isNotEmpty
        ? 'session'
        : 'none';
    debugPrint(
      '[SCHEDULE_DIAG] '
      'user_id_present=${MvpSession.userId.trim().isNotEmpty} '
      'prescription_id_present=${prescriptionId.isNotEmpty} '
      'prescription_id_source=$prescriptionIdSource',
    );
    if (prescriptionId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _applyCachedDays();
      });
      return;
    }
    final userId = MvpSession.userId.trim().isEmpty
        ? 'mvp-user'
        : MvpSession.userId.trim();
    try {
      final response = await _localApi.get(
        '/api/v1/users/$userId/prescriptions/$prescriptionId/schedule-days'
        '?year=$_year&month=$_month',
      );
      if (!mounted) return;
      final onCount = response is Map ? response['on_count'] : null;
      debugPrint(
        '[SCHEDULE_DIAG] http_status=200 on_count=${onCount ?? 'unknown'}',
      );
      _apply(response);
    } on ApiException catch (error) {
      final reason = switch (error.message) {
        '사용자가 없습니다.' => 'user_not_found',
        '처방전을 찾지 못했어요.' => 'prescription_not_found_or_not_owned',
        _ when error.statusCode == null => 'network_or_unknown_error',
        _ => 'http_error',
      };
      debugPrint(
        '[SCHEDULE_DIAG] GET failed '
        'http_status=${error.statusCode ?? 'unknown'} '
        'reason=$reason',
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _applyCachedDays();
      });
    } catch (error) {
      debugPrint(
        '[SCHEDULE_DIAG] GET failed '
        'http_status=unknown error_type=${error.runtimeType}',
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _applyCachedDays();
      });
    }
  }

  void _applyCachedDays() {
    final cached = MvpSession.latestScheduleDates;
    final last = DateTime(_year, _month + 1, 0).day;
    final today = DateTime.now();
    _days = [
      for (int day = 1; day <= last; day++)
        ScheduleDayCell(
          day: day,
          on: cached.contains(
            '${_year.toString().padLeft(4, '0')}-'
            '${_month.toString().padLeft(2, '0')}-'
            '${day.toString().padLeft(2, '0')}',
          ),
          isToday:
              today.year == _year && today.month == _month && today.day == day,
        ),
    ];
    final count = cached.length;
    _headline = count == 0 ? '투약일수를 확인해 주세요' : '오늘부터 $count일, 이 약을 드시는 날이에요';
  }

  void _mergeVisibleOnDaysIntoCache() {
    final next = Set<String>.from(MvpSession.latestScheduleDates);
    for (final day in _days) {
      if (day.day < 1) continue;
      final key =
          '${_year.toString().padLeft(4, '0')}-'
          '${_month.toString().padLeft(2, '0')}-'
          '${day.day.toString().padLeft(2, '0')}';
      if (day.on) {
        next.add(key);
      } else {
        next.remove(key);
      }
    }
    MvpSession.latestScheduleDates = next;
  }

  void _goHome() {
    if (widget.days == null) {
      ref.read(medicationProvider.notifier).refreshFromServer();
      ref.read(userMedicinesProvider.notifier).refresh();
      ref.invalidate(medicationHistoryProvider);
    }
    final onConfirmed = widget.onConfirmed;
    if (onConfirmed != null) {
      onConfirmed();
      return;
    }
    final navigator = Navigator.maybeOf(context);
    if (navigator != null && navigator.canPop()) {
      navigator.popUntil((route) => route.isFirst);
    }
    if (!mounted) return;
    context.go('/');
  }

  void _apply(dynamic response) {
    if (response is! Map) {
      setState(() => _loading = false);
      return;
    }
    final daysRaw = response['days'];
    setState(() {
      _year = (response['year'] as num?)?.toInt() ?? _year;
      _month = (response['month'] as num?)?.toInt() ?? _month;
      _leadingBlanks =
          (response['leading_blanks'] as num?)?.toInt() ?? _leadingBlanks;
      _headline = response['headline']?.toString() ?? _headline;
      _hasTimes = response['has_times'] != false;
      _days = daysRaw is List
          ? [
              for (final row in daysRaw)
                if (row is Map)
                  ScheduleDayCell(
                    day: (row['day'] as num?)?.toInt() ?? 0,
                    on: row['on'] == true,
                    isToday: row['is_today'] == true,
                  ),
            ].where((item) => item.day > 0).toList()
          : _days;
      _loading = false;
      _saving = false;
      _busyDay = null;
    });
    _mergeVisibleOnDaysIntoCache();
  }

  Future<void> _toggle(ScheduleDayCell cell) async {
    if (_saving || _busyDay != null) return;
    if (widget.days != null) {
      setState(() {
        _days = [
          for (final item in _days)
            if (item.day == cell.day)
              ScheduleDayCell(
                day: item.day,
                on: !item.on,
                isToday: item.isToday,
              )
            else
              item,
        ];
        final count = _days.where((item) => item.on).length;
        _headline = count == 0
            ? '투약일수를 확인해 주세요'
            : '오늘부터 $count일, 이 약을 드시는 날이에요';
      });
      _mergeVisibleOnDaysIntoCache();
      return;
    }
    if (!cell.on && !_hasTimes) {
      showSeniorSnackbar(context, '하루 복용 횟수를 확인해 주세요.');
      return;
    }
    final prescriptionId = _prescriptionId;
    if (prescriptionId.isEmpty) return;
    final userId = MvpSession.userId.trim().isEmpty
        ? 'mvp-user'
        : MvpSession.userId.trim();
    final date =
        '${_year.toString().padLeft(4, '0')}-'
        '${_month.toString().padLeft(2, '0')}-'
        '${cell.day.toString().padLeft(2, '0')}';
    setState(() {
      _saving = true;
      _busyDay = cell.day;
    });
    try {
      final response = await _localApi.post(
        '/api/v1/users/$userId/prescriptions/$prescriptionId/schedule-days',
        body: {'date': date},
      );
      if (!mounted) return;
      _apply(response);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _busyDay = null;
      });
      showSeniorSnackbar(context, error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _busyDay = null;
      });
      showSeniorSnackbar(context, '날을 고치지 못했어요. 잠시 후 다시 눌러 주세요.');
    }
  }

  Future<void> _shiftMonth(int delta) async {
    if (_saving || widget.days != null) return;
    var year = _year;
    var month = _month + delta;
    if (month < 1) {
      month = 12;
      year -= 1;
    } else if (month > 12) {
      month = 1;
      year += 1;
    }
    setState(() {
      _year = year;
      _month = month;
      _leadingBlanks = DateTime(_year, _month, 1).weekday - 1;
      if (_leadingBlanks < 0) _leadingBlanks = 6;
      _loading = true;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final cells = <ScheduleDayCell?>[
      for (int i = 0; i < _leadingBlanks; i++) null,
      ..._days,
    ];
    final rowCount = (cells.length / 7).ceil();

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const SeniorBackHeader(title: '약 있는 날'),
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
                        Text(_headline, style: AppText.cardTitle(size: 22)),
                        const SizedBox(height: 8),
                        Text(
                          '파란 테두리 칸이 이 약을 드시는 날이에요. 칸을 누르면 빼거나 넣을 수 있어요.',
                          style: AppText.body(
                            size: 18,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 16),
                        SeniorCard(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 18,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                '$_month월',
                                style: AppText.cardTitle(size: 21),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: _MonthShift(
                                      label: '이전 달',
                                      onPressed: () => _shiftMonth(-1),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: _MonthShift(
                                      label: '다음 달',
                                      onPressed: () => _shiftMonth(1),
                                    ),
                                  ),
                                ],
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
                                                  busy:
                                                      _busyDay ==
                                                      cells[row * 7 + col]!.day,
                                                  onTap: () => _toggle(
                                                    cells[row * 7 + col]!,
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
                        const SizedBox(height: 20),
                        SeniorButton(
                          label: '이대로 좋아요',
                          minHeight: 68,
                          fontSize: 22,
                          onPressed: _goHome,
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

class _MonthShift extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _MonthShift({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.strongLine, width: 2),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: AppText.label(size: 15, color: AppColors.textBody),
          ),
        ),
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  final ScheduleDayCell day;
  final bool busy;
  final VoidCallback onTap;

  const _DayCell(this.day, {required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final background = day.on ? AppColors.secondaryFill : AppColors.surface;
    final ink = day.on ? AppColors.point : AppColors.textPrimary;
    final borderColor = day.on || day.isToday
        ? AppColors.point
        : AppColors.strongLine;
    final spoken = day.on ? '이 약을 드시는 날' : '약 없는 날';
    final todayMark = day.isToday ? '오늘' : '';

    return Semantics(
      button: true,
      selected: day.on,
      label: '${day.day}일 $spoken',
      child: ExcludeSemantics(
        child: Material(
          color: background,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            onTap: busy ? null : onTap,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              constraints: const BoxConstraints(minHeight: 64),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: borderColor, width: 2),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${day.day}',
                    style: AppText.cardTitle(
                      size: 20,
                      color: ink,
                    ).copyWith(height: 1),
                  ),
                  if (todayMark.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      todayMark,
                      style: AppText.label(
                        size: 13,
                        color: ink,
                      ).copyWith(height: 1),
                    ),
                  ],
                ],
              ),
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
    return Row(
      children: [
        _swatch(AppColors.secondaryFill, AppColors.point),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '이 약을 드시는 날',
            style: AppText.label(size: 16, color: AppColors.textSecondary),
          ),
        ),
        _swatch(AppColors.surface, AppColors.strongLine),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '약 없는 날',
            style: AppText.label(size: 16, color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }

  Widget _swatch(Color fill, Color border) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border, width: 2),
      ),
    );
  }
}
