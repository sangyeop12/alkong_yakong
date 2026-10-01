import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../domain/medication_models.dart';

/// 복약 체크의 예외 경로를 막아서는 바텀시트들.
///
/// 기억이 흐려 한 번 더 먹는 상황은 실제 위험이다.
/// 사후 안내가 아니라 **사전 차단**이므로, 시트가 뜨는 동안에는
/// 기본 동작이 "아무것도 하지 않고 닫기"다.

Future<T?> _showGuardSheet<T>(BuildContext context, Widget child) {
  return showModalBottomSheet<T>(
    context: context,
    // 뒤 화면은 흐려지고, 바깥을 눌러도 닫히지 않는다 — 실수로 지나치지 않게.
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    barrierColor: AppColors.sheetScrim,
    backgroundColor: Colors.transparent,
    builder: (_) => child,
  );
}

class _GuardSheet extends StatelessWidget {
  final List<Widget> children;
  const _GuardSheet({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        boxShadow: [
          BoxShadow(
            color: AppColors.sheetShadow,
            blurRadius: 40,
            offset: Offset(0, -12),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 52,
                  height: 5,
                  decoration: BoxDecoration(
                    color: AppColors.chartPast,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// 기록 증거 박스 — **절대시간을 앞에, 상대시간은 보조로**.
class _RecordProof extends StatelessWidget {
  final DateTime takenAt;
  const _RecordProof({required this.takenAt});

  String get _relative {
    final minutes = DateTime.now().difference(takenAt).inMinutes;
    if (minutes < 1) return '방금';
    if (minutes < 60) return '$minutes분 전';
    return '${minutes ~/ 60}시간 전';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: AppColors.pointTint,
              shape: BoxShape.circle,
            ),
            child: Text(
              '✓',
              style: AppText.cardTitle(size: 20, color: AppColors.point),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${DoseSlot.absoluteTime(takenAt)}에 기록',
                  style: AppText.cardTitle(size: 19),
                ),
                Text(_relative, style: AppText.caption()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 5f — 두 번 눌렀을 때 (중복 복용 차단).
///
/// 기본 동작은 "알겠어요"로 아무것도 하지 않고 닫는 것이다.
/// 되돌리기를 골랐으면 [onUndo]가 불린다.
Future<void> showDuplicateDoseSheet({
  required BuildContext context,
  required DoseEntry dose,
  required VoidCallback onUndo,
}) {
  final takenAt = dose.takenAt ?? DateTime.now();
  return _showGuardSheet<void>(
    context,
    _GuardSheet(
      children: [
        Text(
          '${dose.slot.label} 약은 이미\n드신 것으로 되어 있어요',
          style: AppText.emphasis(size: 27),
        ),
        const SizedBox(height: 14),
        _RecordProof(takenAt: takenAt),
        const SizedBox(height: 14),
        Text.rich(
          TextSpan(
            style: AppText.body(),
            children: [
              const TextSpan(text: '한 번 더 드시면 약이 겹칠 수 있어요. '),
              TextSpan(
                text: '지금은 드시지 마세요.',
                style: AppText.body(
                  weight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SeniorButton(
          label: '알겠어요',
          fontSize: 23,
          onPressed: () => Navigator.of(context).pop(),
        ),
        const SizedBox(height: 12),
        // 회색 텍스트 링크를 액션으로 쓰지 않는다. 눌리는 면을 준다.
        SeniorButton(
          label: '기록이 잘못됐어요 · 되돌리기',
          kind: SeniorButtonKind.secondary,
          minHeight: 62,
          fontSize: 19,
          onPressed: () {
            Navigator.of(context).pop();
            onUndo();
          },
        ),
      ],
    ),
  );
}

/// 지연 복약 — 복약 시각에서 4시간 이상 지난 뒤 체크했을 때.
/// "그래도 먹었어요"를 고르면 true를 돌려준다.
Future<bool> showLateDoseSheet({
  required BuildContext context,
  required DoseSlot slot,
}) async {
  final result = await _showGuardSheet<bool>(
    context,
    _GuardSheet(
      children: [
        Text('${slot.label} 약 시간이\n한참 지났어요', style: AppText.emphasis(size: 27)),
        const SizedBox(height: 14),
        Text(
          '지금 드시면 다음 약과 너무 가까워질 수 있어요. '
          '약사님께 먼저 여쭤보시면 좋아요.',
          style: AppText.body(),
        ),
        const SizedBox(height: 14),
        SeniorButton(
          label: '약사님께 물어보기',
          fontSize: 23,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SeniorTextButton(
          label: '그래도 먹었어요',
          fontSize: 18.5,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 약을 건너뛴 채 다음 시간대에 도달했을 때.
/// 이전 시간대를 "안 드셨어요"로 **자동 확정하지 않고** 한 번 물어본다.
/// 드셨다고 답하면 true.
Future<bool> askSkippedDose({
  required BuildContext context,
  required DoseSlot slot,
}) async {
  final result = await _showGuardSheet<bool>(
    context,
    _GuardSheet(
      children: [
        Text('${slot.label} 약은 드셨나요?', style: AppText.emphasis(size: 27)),
        const SizedBox(height: 14),
        Text(
          '${slot.spokenTime} 약이 기록되지 않았어요. '
          '드셨는데 누르지 못하셨을 수도 있어서 여쭤봐요.',
          style: AppText.body(),
        ),
        const SizedBox(height: 14),
        SeniorButton(
          label: '네, 드셨어요',
          fontSize: 23,
          onPressed: () => Navigator.of(context).pop(true),
        ),
        const SizedBox(height: 10),
        SeniorButton(
          label: '아니요, 안 드셨어요',
          kind: SeniorButtonKind.secondary,
          minHeight: 60,
          fontSize: 20,
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ],
    ),
  );
  return result ?? false;
}
