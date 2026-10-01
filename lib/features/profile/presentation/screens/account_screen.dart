import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/session/mvp_session.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_feedback.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../application/current_user_controller.dart';
import '../../application/session_actions.dart';

/// 계정 관리 — 로그아웃·탈퇴 전용 하위 화면.
///
/// 위험 동작을 "내 정보"에서 떼어내 여기로 옮겼다.
/// 안전한 버튼(가족 초대, 약 목록)과 물리적으로 떨어져 있어야
/// 잘못 누르는 일이 줄어든다.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const SeniorBackHeader(title: '계정 관리'),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 16,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('로그아웃', style: AppText.cardTitle(size: 21)),
                        const SizedBox(height: 6),
                        Text(
                          '다시 들어오시려면 휴대폰 번호와 비밀번호가 필요해요. '
                          '기록은 그대로 남아 있어요.',
                          style: AppText.body(),
                        ),
                        const SizedBox(height: 16),
                        SeniorButton(
                          label: '로그아웃',
                          kind: SeniorButtonKind.secondary,
                          minHeight: 62,
                          fontSize: 21,
                          onPressed: () async {
                            await endSession(ref);
                            if (context.mounted) context.go('/login');
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 16,
                    ),
                    borderColor: AppColors.dangerBorder,
                    borderWidth: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '탈퇴',
                          style: AppText.cardTitle(
                            size: 21,
                            color: AppColors.danger,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '탈퇴하시면 복약 기록과 등록한 약이 모두 지워지고 '
                          '되돌릴 수 없어요. 가족에게도 더 이상 알림이 가지 않아요.',
                          style: AppText.body(),
                        ),
                        const SizedBox(height: 16),
                        SeniorButton(
                          label: '탈퇴',
                          kind: SeniorButtonKind.danger,
                          minHeight: 62,
                          fontSize: 21,
                          onPressed: () => _confirmWithdraw(context, ref),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmWithdraw(BuildContext context, WidgetRef ref) async {
    final go = await showSeniorYesNoDialog(
      context: context,
      title: '정말 탈퇴하시겠어요?',
      message: '지금까지의 복약 기록이 모두 지워져요. 한 번 지우면 되돌릴 수 없어요.',
      yesLabel: '아니요, 그냥 둘게요',
      noLabel: '네, 탈퇴할게요',
    );
    // 위쪽(주 버튼)이 "그냥 둘게요"다. 위험한 쪽을 크게 두지 않는다.
    if (go || !context.mounted) return;
    await _withdraw(context, ref);
  }

  /// 서버에서 지워진 뒤에만 나간다. 못 지웠는데 나가면
  /// 그만둔 줄 알았던 계정이 그대로 남는다.
  Future<void> _withdraw(BuildContext context, WidgetRef ref) async {
    final userId =
        ref.read(currentUserProvider).valueOrNull?.id ??
        MvpSession.userId.trim();
    try {
      await ref.read(userRepositoryProvider).delete(userId);
    } on ApiException catch (error) {
      if (context.mounted) {
        showSeniorSnackbar(context, error.message, error: true);
      }
      return;
    }
    await endSession(ref);
    if (context.mounted) context.go('/login');
  }
}
