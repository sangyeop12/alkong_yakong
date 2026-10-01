import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../../core/widgets/senior_feedback.dart';
import '../../../profile/application/session_actions.dart';
import '../../../dashboard/presentation/screens/profile_edit_screen.dart';
import '../../../profile/application/current_user_controller.dart';

/// 보호자 · 내 계정 (프로토타입 94).
///
/// 이름·휴대폰·비밀번호를 한 줄씩 보여주고, 아래에 로그아웃과 탈퇴를 둔다.
class GuardianAccountScreen extends ConsumerWidget {
  const GuardianAccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentUserProvider).valueOrNull;

    void openEdit() => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ProfileEditScreen(isGuardian: true),
      ),
    );

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const SeniorBackHeader(title: '내 계정', alignStart: true),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('내 정보', style: AppText.label(size: 18)),
                  const SizedBox(height: 8),
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 4,
                    ),
                    child: Column(
                      children: [
                        SeniorListRow(
                          label: '이름',
                          value: profile?.name ?? '',
                          trailing: const SeniorChevron(),
                          onTap: openEdit,
                        ),
                        const SeniorDivider(),
                        SeniorListRow(
                          label: '휴대폰',
                          value: profile?.phone ?? '',
                          trailing: const SeniorChevron(),
                          onTap: openEdit,
                        ),
                        const SeniorDivider(),
                        SeniorListRow(
                          label: '비밀번호',
                          value: '••••••',
                          trailing: const SeniorChevron(),
                          onTap: openEdit,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text('계정 정리', style: AppText.label(size: 18)),
                  const SizedBox(height: 8),
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 4,
                    ),
                    child: Column(
                      children: [
                        SeniorListRow(
                          label: '이 전화기에서 로그아웃',
                          trailing: const SeniorChevron(),
                          onTap: () => _logout(context, ref),
                        ),
                        const SeniorDivider(),
                        SeniorListRow(
                          label: '탈퇴하기',
                          labelColor: AppColors.danger,
                          trailing: const SeniorChevron(
                            color: AppColors.danger,
                          ),
                          onTap: () => _withdraw(context, ref),
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

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final go = await showSeniorYesNoDialog(
      context: context,
      title: '로그아웃할까요?',
      message: '다시 들어오시려면 휴대폰 번호와 비밀번호가 필요해요. 기록은 그대로 남아 있어요.',
      yesLabel: '네, 로그아웃할게요',
      noLabel: '그냥 둘게요',
    );
    if (!go || !context.mounted) return;
    await endSession(ref);
    if (context.mounted) context.go('/login');
  }

  Future<void> _withdraw(BuildContext context, WidgetRef ref) async {
    final stay = await showSeniorYesNoDialog(
      context: context,
      title: '정말 탈퇴하시겠어요?',
      message: '돌보는 분과의 연결이 모두 끊어지고, 되돌릴 수 없어요.',
      yesLabel: '아니요, 그냥 둘게요',
      noLabel: '네, 탈퇴할게요',
    );
    // 위쪽(주 버튼)이 "그냥 둘게요"다. 위험한 쪽을 크게 두지 않는다.
    if (stay || !context.mounted) return;
    await endSession(ref);
    if (context.mounted) context.go('/login');
  }
}
