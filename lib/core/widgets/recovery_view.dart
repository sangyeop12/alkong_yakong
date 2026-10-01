import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../theme/app_typography.dart';
import 'senior_button.dart';
import 'senior_card.dart';

/// 5e — 오류 회복 화면의 공용 구성.
///
/// 어르신은 오류 화면에서 멈춘다. 오류가 아니라 **다음에 할 일**을 보여준다.
/// 구성은 언제나 다섯 조각이다:
/// ① 무슨 일인지 ② 고장이 아니라는 안심 ③ 번호 붙은 회복 단계
/// ④ 여전히 되는 것 ⑤ 사람에게 연결.
///
/// 인터넷 없음 · 처방전 인식 실패 · 로그인 실패 · 서버 오류에 모두 이 패턴을 쓴다.
class RecoveryView extends StatelessWidget {
  /// ① 무슨 일인지. "지금은 심장 박동을\n재지 못하고 있어요"
  final String title;

  /// ② 안심 문장의 앞부분.
  final String reassurance;

  /// ② 안심 문장에서 굵게 읽힐 부분. "고장이 아니니 걱정하지 마세요."
  final String reassuranceEmphasis;

  /// ③ 번호가 붙는 회복 단계.
  final List<String> steps;

  final String actionLabel;
  final VoidCallback onAction;

  /// ④ 무엇이 여전히 동작하는지 — **반드시 알린다.**
  final String stillWorksTitle;
  final String stillWorksBody;

  /// ⑤ 사람에게 연결.
  final String? helperText;
  final VoidCallback? onCallHelper;

  /// 절대시간 각주. "마지막으로 잰 시각 · 오늘 오전 11시 20분"
  final String? footnote;

  const RecoveryView({
    super.key,
    required this.title,
    required this.reassurance,
    required this.reassuranceEmphasis,
    required this.steps,
    required this.actionLabel,
    required this.onAction,
    required this.stillWorksTitle,
    required this.stillWorksBody,
    this.helperText,
    this.onCallHelper,
    this.footnote,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SeniorCard(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: AppText.emphasis()),
                const SizedBox(height: 12),
                Text.rich(
                  TextSpan(
                    style: AppText.body(),
                    children: [
                      TextSpan(text: reassurance),
                      TextSpan(
                        text: reassuranceEmphasis,
                        style: AppText.body(
                          weight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 15,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.bg,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    children: [
                      for (int i = 0; i < steps.length; i++) ...[
                        if (i > 0) const SizedBox(height: 11),
                        _Step(number: i + 1, text: steps[i]),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SeniorButton(
                  label: actionLabel,
                  fontSize: 23,
                  onPressed: onAction,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ④ 여전히 되는 것
          SeniorCard(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(stillWorksTitle, style: AppText.cardTitle(size: 19)),
                const SizedBox(height: 4),
                Text(stillWorksBody, style: AppText.caption()),
              ],
            ),
          ),

          // ⑤ 사람에게 연결
          if (helperText != null) ...[
            const SizedBox(height: 12),
            SeniorCard(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      helperText!,
                      style: AppText.cardTitle(size: 19),
                    ),
                  ),
                  const SizedBox(width: 12),
                  InkWell(
                    onTap: onCallHelper,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 52),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      decoration: BoxDecoration(
                        color: AppColors.pointTint,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '알리기',
                        style: AppText.cardTitle(
                          size: 18,
                          color: AppColors.point,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          if (footnote != null) ...[
            const SizedBox(height: 16),
            Text(
              footnote!,
              textAlign: TextAlign.center,
              style: AppText.caption(size: 17),
            ),
          ],
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final int number;
  final String text;
  const _Step({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: AppColors.point,
            shape: BoxShape.circle,
          ),
          child: Text(
            '$number',
            style: AppText.cardTitle(size: 16, color: Colors.white),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: AppText.label(size: 18.5, color: AppColors.textPrimary),
          ),
        ),
      ],
    );
  }
}
