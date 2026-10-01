import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../theme/app_typography.dart';

/// 상단 바의 주간 날짜 스트립 (3a).
///
/// 오늘만 포인트색을 쓴다 — 요일은 26×26 파란 원, 날짜는 40×40 파란 원.
/// 나머지 날짜는 무채색 칩이다.
/// 칩 자체는 40×40이지만 탭 영역은 요일 라벨까지 포함해 48px를 넘긴다.
class WeekDateStrip extends StatelessWidget {
  final DateTime today;
  final DateTime? selected;
  final ValueChanged<DateTime>? onSelect;

  const WeekDateStrip({
    super.key,
    required this.today,
    this.selected,
    this.onSelect,
  });

  static const List<String> _weekdayLabels = [
    '월',
    '화',
    '수',
    '목',
    '금',
    '토',
    '일',
  ];

  @override
  Widget build(BuildContext context) {
    // 월요일부터 시작하는 이번 주.
    final monday = DateTime(
      today.year,
      today.month,
      today.day,
    ).subtract(Duration(days: today.weekday - 1));

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (int i = 0; i < 7; i++)
          _DayCell(
            date: monday.add(Duration(days: i)),
            weekdayLabel: _weekdayLabels[i],
            isToday: _sameDay(monday.add(Duration(days: i)), today),
            onTap: onSelect,
          ),
      ],
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _DayCell extends StatelessWidget {
  final DateTime date;
  final String weekdayLabel;
  final bool isToday;
  final ValueChanged<DateTime>? onTap;

  const _DayCell({
    required this.date,
    required this.weekdayLabel,
    required this.isToday,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      selected: isToday,
      label:
          '${date.month}월 ${date.day}일 $weekdayLabel요일${isToday ? ', 오늘' : ''}',
      child: InkResponse(
        onTap: onTap == null ? null : () => onTap!(date),
        radius: 34,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isToday)
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: AppColors.point,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    weekdayLabel,
                    style: AppText.tab(
                      active: true,
                    ).copyWith(fontSize: 14, color: Colors.white),
                  ),
                )
              else
                SizedBox(
                  height: 26,
                  child: Center(
                    child: Text(
                      weekdayLabel,
                      style: AppText.label(
                        size: 16,
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 6),
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isToday ? AppColors.point : AppColors.chipBg,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '${date.day}',
                  style: TextStyle(
                    fontSize: 19,
                    height: 1,
                    fontWeight: isToday ? FontWeight.w700 : FontWeight.w700,
                    color: isToday ? Colors.white : AppColors.inkGray,
                    fontFamily: AppText.fontFamily,
                    fontFamilyFallback: AppText.fontFallback,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
