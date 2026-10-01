import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../profile/application/current_user_controller.dart';
import '../../../profile/presentation/screens/help_screen.dart';
import '../../../profile/presentation/screens/policy_screen.dart';
import '../../application/guardians_provider.dart';
import 'guardian_account_screen.dart';
import 'guardian_alert_prefs_screen.dart';
import 'care_manage_screen.dart';

/// 보호자 · 정보 탭 (프로토타입 93).
///
/// 어르신 화면의 "내 정보"와 다르다. 보호자는 약을 먹지 않으니
/// 내 약 목록·복약 알림·폴라 센서가 없다.
class GuardianInfoScreen extends ConsumerWidget {
  const GuardianInfoScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final profile = user.valueOrNull;
    final patients =
        ref.watch(careOverviewProvider).valueOrNull?.patients ?? const [];

    return Column(
      children: [
        const SeniorTitleHeader(title: '정보'),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SeniorCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const GuardianAccountScreen(),
                    ),
                  ),
                  child: Row(
                    children: [
                      InitialAvatar(
                        name: profile?.name ?? '',
                        size: 64,
                        background: AppColors.pointTint,
                        foreground: AppColors.point,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              profile?.name ?? '불러오는 중이에요',
                              style: AppText.cardTitle(size: 23),
                            ),
                            if ((profile?.phone ?? '').isNotEmpty)
                              Text(
                                profile!.phone!,
                                style: AppText.body(
                                  size: 18,
                                  color: AppColors.textTertiary,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      const SeniorChevron(),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SeniorCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 4,
                  ),
                  child: Column(
                    children: [
                      SeniorListRow(
                        label: '돌보는 분 관리',
                        icon: TablerIcons.users,
                        value: patients.isEmpty ? null : '${patients.length}명',
                        trailing: const SeniorChevron(),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const CareManageScreen(),
                          ),
                        ),
                      ),
                      const SeniorDivider(),
                      SeniorListRow(
                        label: '알림 받는 방법',
                        icon: TablerIcons.bell,
                        trailing: const SeniorChevron(),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const GuardianAlertPrefsScreen(),
                          ),
                        ),
                      ),
                      const SeniorDivider(),
                      SeniorListRow(
                        label: '도움말',
                        icon: TablerIcons.help_circle,
                        trailing: const SeniorChevron(),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const HelpScreen(),
                          ),
                        ),
                      ),
                      const SeniorDivider(),
                      SeniorListRow(
                        label: '약관 · 개인정보',
                        icon: TablerIcons.file_text,
                        trailing: const SeniorChevron(),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const PolicyScreen.terms(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
