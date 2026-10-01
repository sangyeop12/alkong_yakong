import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../medication/domain/medication_models.dart';

/// 하루치 복약 결과 한 장.
///
/// 기록 탭과 달력 화면이 같은 것을 쓴다. 날짜 하나를 놓고 **시간대별로
/// 드셨는지**만 말한다. 날짜를 여러 장 쌓지 않는다 — 같은 내용을 달력에서
/// 또 보게 되기 때문이다.
class DayDoseDetail extends StatelessWidget {
  /// "9월 18일 오늘"처럼 어느 날인지.
  final String dayLabel;

  /// 그날의 시간대별 상태.
  final List<DoseEntry> doses;

  /// 어느 날인지. 지난 날은 시각과 상관없이 "못 드셨어요"로 읽는다.
  final DateTime? date;

  /// 카드 아래 안내. 날짜를 누르면 내용이 바뀐다는 것을 알려준다.
  /// 아래 한 줄 안내. null이면 줄 자체를 그리지 않는다.
  final String? footnote;

  const DayDoseDetail({
    super.key,
    required this.dayLabel,
    required this.doses,
    this.footnote,
    this.date,
  });

  /// 오른쪽 위 요약. 남은 것이 없으면 다 드셨다고 말한다.
  String get _headline {
    if (doses.isEmpty) return '기록이 없어요';
    final left = doses.where((dose) => !dose.taken).toList();
    if (left.isEmpty) return '다 드셨어요';
    return '${left.first.slot.label} ${left.length}번 남았어요';
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SeniorCard(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(dayLabel, style: AppText.cardTitle(size: 20)),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        _headline,
                        style: AppText.label(
                          size: 17.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              for (final dose in doses) ...[
                const SizedBox(height: 14),
                _SlotRow(dose: dose, now: now, date: date ?? now),
              ],
            ],
          ),
        ),
        if (footnote case final String note) ...[
          const SizedBox(height: 8),
          Text(
            note,
            style: AppText.caption(size: 16.5, color: AppColors.textTertiary),
          ),
        ],
      ],
    );
  }
}

/// 한 시간대 — 이름, 표시, 상태말.
class _SlotRow extends StatelessWidget {
  final DoseEntry dose;
  final DateTime now;

  /// 이 카드가 말하는 날.
  final DateTime date;

  const _SlotRow({required this.dose, required this.now, required this.date});

  /// 아직 오지 않은 때는 "못 드셨어요"라고 말하지 않는다.
  bool get _missed {
    if (dose.taken) return false;
    final day = DateTime(date.year, date.month, date.day);
    final today = DateTime(now.year, now.month, now.day);
    if (day.isBefore(today)) return true;
    if (day.isAfter(today)) return false;
    return dose.slot.todayAt(now).isBefore(now);
  }

  String get _state {
    if (dose.taken) return '드셨어요';
    return _missed ? '못 드셨어요' : '아직이에요';
  }

  @override
  Widget build(BuildContext context) {
    final taken = dose.taken;
    final color = taken
        ? AppColors.point
        : (_missed ? AppColors.danger : AppColors.textTertiary);

    return Semantics(
      label: '${dose.slot.label} $_state',
      child: ExcludeSemantics(
        child: Row(
          children: [
            SizedBox(
              width: 58,
              child: Text(dose.slot.label, style: AppText.label(size: 18.5)),
            ),
            const SizedBox(width: 10),
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: taken ? AppColors.pointTint : AppColors.bg,
                shape: BoxShape.circle,
              ),
              child: Icon(
                taken
                    ? TablerIcons.check
                    : (_missed ? TablerIcons.x : TablerIcons.point),
                size: taken || _missed ? 20 : 14,
                color: color,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(_state, style: AppText.body(size: 18, color: color)),
            ),
          ],
        ),
      ),
    );
  }
}
