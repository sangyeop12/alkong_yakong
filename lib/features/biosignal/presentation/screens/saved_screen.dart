import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../domain/heart_time.dart';
import '../../domain/heart_data.dart';

/// 30 · 기록 저장.
///
/// 무엇이 남았는지만 말한다 — 심박수 기록, 그리고 넘겨받았으면 복약 기록.
/// 넘겨받지 않은 복약 내용("저녁 약 3가지" 같은)을 지어 적지 않는다.
class SavedScreen extends StatelessWidget {
  final int bpm;
  final String guardianTitle;

  /// 심박수 이상 화면을 거쳐 왔는지. 문구가 달라진다.
  final bool fromAlert;

  /// 함께 남은 복약 기록 한 줄. 예: "저녁 약 3가지 · 오후 6시 2분에 드셨어요".
  /// 없으면 복약 기록 칸을 그리지 않는다.
  final String? doseSummary;

  /// 저장한 시각. 없으면 화면을 여는 지금 시각을 쓴다.
  final DateTime? savedAt;
  final HeartMeasurementContext measurementContext;

  /// 기록 탭으로 보내는 길. 없으면 버튼을 그리지 않는다.
  final VoidCallback? onOpenRecord;

  /// 심박수 관리 화면에서 시작한 측정이면, 그 화면으로만 돌아간다.
  /// 다른 진입 경로는 기존의 최상위 경로 복귀 동작을 유지한다.
  final bool returnToPreviousScreen;
  final Future<void> Function()? onConfirmed;

  const SavedScreen({
    super.key,
    required this.bpm,
    this.guardianTitle = '',
    this.fromAlert = false,
    this.doseSummary,
    this.savedAt,
    this.measurementContext = HeartMeasurementContext.general,
    this.onOpenRecord,
    this.returnToPreviousScreen = false,
    this.onConfirmed,
  });

  Future<void> _confirm(BuildContext context) async {
    if (returnToPreviousScreen) {
      final router = GoRouter.maybeOf(context);
      if (router != null) {
        // MaterialRoute와 GoRoute가 섞인 스택을 pop 횟수로 추측하지 않고,
        // 심박수 관리 화면을 명시적인 복귀 대상으로 지정한다.
        await onConfirmed?.call();
        if (context.mounted) router.go('/biosignal');
        return;
      }
    }
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      if (returnToPreviousScreen) {
        navigator.pop(true);
        return;
      }
      navigator.popUntil((route) => route.isFirst);
      return;
    }
    // A replacement can leave this as the navigator's first route. In that
    // case popUntil is a no-op; return to the real heart records route.
    GoRouter.maybeOf(context)?.go('/biosignal');
  }

  @override
  Widget build(BuildContext context) {
    final at = heartSavedTimeLabel(savedAt ?? DateTime.now());
    final doseSummary = this.doseSummary;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const SeniorBackHeader(title: '기록 저장'),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 92,
                      height: 92,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        color: AppColors.pointTint,
                        shape: BoxShape.circle,
                      ),
                      child: const ExcludeSemantics(
                        child: Icon(
                          TablerIcons.check,
                          size: 50,
                          color: AppColors.point,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    '잘 저장되었어요',
                    textAlign: TextAlign.center,
                    style: AppText.emphasis(size: 27),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$at 기준으로\n아래 기록이 남았습니다.',
                    textAlign: TextAlign.center,
                    style: AppText.body(
                      size: 18.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (doseSummary != null && doseSummary.isNotEmpty) ...[
                    _SavedItem(
                      icon: TablerIcons.pill,
                      title: '복약 기록',
                      description: doseSummary,
                    ),
                    const SizedBox(height: 12),
                  ],
                  _SavedItem(
                    icon: TablerIcons.activity_heartbeat,
                    title: '심박수 기록',
                    description:
                        '$bpm회 / 분 · ${measurementContext.label} · 서버에 저장된 심박수',
                  ),
                  const SizedBox(height: 20),
                  SeniorButton(
                    label: '확인했어요',
                    minHeight: 74,
                    fontSize: 24,
                    onPressed: () => _confirm(context),
                  ),
                  if (onOpenRecord != null) ...[
                    const SizedBox(height: 12),
                    SeniorButton(
                      label: '기록 보러 가기',
                      kind: SeniorButtonKind.secondary,
                      minHeight: 66,
                      fontSize: 21,
                      onPressed: onOpenRecord,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// GoRouter가 관리하는 저장 완료 경로에 전달하는 내부 화면 인자.
class HeartSavedRouteArgs {
  final int bpm;
  final DateTime? savedAt;
  final HeartMeasurementContext measurementContext;
  final String guardianTitle;
  final Future<void> Function()? onSaved;

  const HeartSavedRouteArgs({
    required this.bpm,
    required this.savedAt,
    required this.measurementContext,
    required this.guardianTitle,
    this.onSaved,
  });
}

class _SavedItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _SavedItem({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return SeniorCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: AppColors.pointTint,
              shape: BoxShape.circle,
            ),
            child: ExcludeSemantics(
              child: Icon(icon, size: 28, color: AppColors.point),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.cardTitle(size: 20)),
                Text(description, style: AppText.caption(size: 17.5)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          const ExcludeSemantics(
            child: Icon(
              TablerIcons.circle_check_filled,
              size: 26,
              color: AppColors.point,
            ),
          ),
        ],
      ),
    );
  }
}
