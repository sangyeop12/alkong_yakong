import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_feedback.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../dashboard/presentation/screens/profile_edit_screen.dart';
import '../../../dashboard/presentation/screens/settings_menu.dart';
import '../../../guardian/application/guardians_provider.dart';
import '../../../guardian/data/guardian_repository.dart';
import '../../../guardian/presentation/widgets/add_care_sheet.dart';
import '../../../medication/application/medication_controller.dart';
import '../../../reminder/application/alarm_preferences.dart';
import '../../../reminder/presentation/screens/alarm_settings_screen.dart';
import '../../../biosignal/presentation/screens/polar_screen.dart';
import '../../../medicines/application/user_medicines_controller.dart';
import '../../application/current_user_controller.dart';
import 'account_screen.dart';

/// 4h — 내 정보 · 설정.
///
/// 로그아웃·탈퇴 같은 위험 동작은 이 화면에 두지 않는다.
/// [AccountScreen]으로 분리하고, 안전한 버튼과 물리적으로 떨어뜨렸다.
///
/// 이 화면의 글자는 모두 저장된 값에서 온다. 고치고 돌아오면 바로 바뀐다.
class MyPageScreen extends ConsumerStatefulWidget {
  /// 보호자 화면에서 열렸는지. 문구만 달라지고 색은 같다.
  final bool isGuardian;

  const MyPageScreen({super.key, this.isGuardian = false});

  @override
  ConsumerState<MyPageScreen> createState() => _MyPageScreenState();
}

class _MyPageScreenState extends ConsumerState<MyPageScreen> {
  /// 39 시트를 그대로 쓴다. 보호자 화면에 있는 것과 같은 길이다.
  Future<void> _inviteFamily() async {
    final draft = await showAddCareSheet(context);
    if (draft == null || !mounted) return;
    final result = await GuardianRepository().invite(
      name: draft.name,
      relation: draft.relation,
      phone: draft.phone,
    );
    if (!mounted) return;
    if (result.isSent) {
      ref.invalidate(guardiansProvider);
      ref.read(medicationProvider.notifier).refreshFromServer();
    }
    // 서버가 받아 준 뒤에만 보냈다고 말한다.
    showSeniorSnackbar(
      context,
      result.isSent
          ? '${draft.name} 님에게 초대를 보냈어요'
          : result.error ?? '초대를 보내지 못했어요',
      error: !result.isSent,
    );
  }

  /// 보호자가 먼저 청한 연결에 대답한다. 거절은 요청을 지운다.
  Future<void> _answerRequest(GuardianContact guardian, bool accept) async {
    final repository = GuardianRepository();
    try {
      if (accept) {
        await repository.accept(guardian.id);
      } else {
        await repository.remove(guardian.id);
      }
    } on ApiException catch (error) {
      if (mounted) showSeniorSnackbar(context, error.message, error: true);
      return;
    }
    if (!mounted) return;
    ref.invalidate(guardiansProvider);
    ref.read(medicationProvider.notifier).refreshFromServer();
    showSeniorSnackbar(
      context,
      accept
          ? '${guardian.name} 님이 이제 함께 볼 수 있어요'
          : '${guardian.name} 님의 요청을 거절했어요',
    );
  }

  @override
  Widget build(BuildContext context) {
    final today = ref.watch(medicationProvider);
    final user = ref.watch(currentUserProvider);
    final profile = user.valueOrNull;
    final guardians = ref.watch(guardiansProvider);
    final alarm = ref.watch(alarmPreferencesProvider);
    final medicines = ref.watch(userMedicinesProvider);
    final medicineCount = medicines.maybeWhen(
      data: (items) => items.length,
      orElse: () => today.doses
          .expand((d) => d.medicines.map((m) => m.medicineCode ?? m.ingredient))
          .toSet()
          .length,
    );
    final loadFailed = profile == null && user.hasError;
    final ageLine = profile?.ageLine(DateTime.now()) ?? '';

    return Column(
      children: [
        const SeniorTitleHeader(title: '내 정보'),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── 프로필 ──
                SeniorCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
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
                              profile?.name ??
                                  (loadFailed ? '내 정보' : '불러오는 중이에요'),
                              style: AppText.cardTitle(size: 23),
                            ),
                            if (loadFailed)
                              Text(
                                '내 정보를 불러오지 못했어요',
                                style: AppText.body(
                                  size: 18,
                                  color: AppColors.danger,
                                ),
                              )
                            else if (ageLine.isNotEmpty)
                              Text(
                                ageLine,
                                style: AppText.body(
                                  size: 18,
                                  color: AppColors.textTertiary,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      SeniorTextButton(
                        label: loadFailed ? '다시' : '고치기',
                        expand: false,
                        color: AppColors.point,
                        fontSize: 18,
                        onPressed: loadFailed
                            ? () => ref.invalidate(currentUserProvider)
                            : () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => ProfileEditScreen(
                                    isGuardian: widget.isGuardian,
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // ── 설정 목록 ──
                SeniorCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 4,
                  ),
                  child: Column(
                    children: [
                      SeniorListRow(
                        label: '내 약 목록',
                        icon: TablerIcons.pill,
                        value: '$medicineCount가지',
                        trailing: const SeniorChevron(),
                        onTap: () => context.push('/my-medicines'),
                      ),
                      const SeniorDivider(),
                      SeniorListRow(
                        label: '복약 알림',
                        icon: TablerIcons.bell,
                        // 소리로 알려주기만 한다. 말로 기록하는 기능은 없다.
                        subtitle: alarm.summary,
                        trailing: const SeniorChevron(),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const AlarmSettingsScreen(),
                          ),
                        ),
                      ),
                      const SeniorDivider(),
                      SeniorListRow(
                        label: '폴라 센서',
                        icon: TablerIcons.heart,
                        // 여기서는 연결 여부를 모른다. 들어가야 센서를 찾는다.
                        subtitle: '심박 센서 연결 · 차는 방법',
                        trailing: const SeniorChevron(),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const PolarScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // ── 함께 보는 가족 ── (어르신만. 보호자는 돌보는 분 탭에서 본다)
                if (!widget.isGuardian) ...[
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 14,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        IconTitle(
                          icon: TablerIcons.users,
                          text: '함께 보는 가족',
                          style: AppText.cardTitle(size: 19),
                        ),
                        const SizedBox(height: 14),
                        ...guardians.when(
                          loading: () => [
                            Text('불러오는 중이에요', style: AppText.caption()),
                          ],
                          error: (_, _) => [
                            Text(
                              '가족 목록을 불러오지 못했어요',
                              style: AppText.caption(color: AppColors.danger),
                            ),
                          ],
                          data: (list) => list.isEmpty
                              ? [
                                  Text(
                                    '아직 함께 보는 가족이 없어요. '
                                    '초대하면 약을 놓쳤을 때 알려드려요.',
                                    style: AppText.body(size: 17.5),
                                  ),
                                ]
                              : [
                                  for (int i = 0; i < list.length; i++) ...[
                                    if (i > 0) const SizedBox(height: 12),
                                    _GuardianRow(
                                      guardian: list[i],
                                      onAnswer: (accept) =>
                                          _answerRequest(list[i], accept),
                                    ),
                                  ],
                                ],
                        ),
                        const SizedBox(height: 14),
                        // 보호자 계정은 따로 있다. 여기서 열리지 않는다는 사실을
                        // 미리 적어 두지 않으면 "안 열린다"는 문의가 된다.
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 16,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.sunken,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            '가족은 따로 가입한 보호자 계정으로 봅니다. '
                            '어르신 화면에서는 보호자 화면이 열리지 않아요.',
                            style: AppText.body(size: 17.5),
                          ),
                        ),
                        const SizedBox(height: 14),
                        SeniorButton(
                          label: guardians.valueOrNull?.isNotEmpty ?? false
                              ? '가족 더 초대하기'
                              : '가족 초대하기',
                          kind: SeniorButtonKind.secondary,
                          minHeight: 58,
                          fontSize: 20,
                          onPressed: _inviteFamily,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // ── 도움말 ──
                const SettingsMenu(),
                const SizedBox(height: 12),

                // ── 계정 (위험 동작은 하위 화면으로 분리) ──
                SeniorCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 4,
                  ),
                  child: SeniorListRow(
                    label: '계정 관리',
                    icon: TablerIcons.user,
                    trailing: const SeniorChevron(),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AccountScreen(),
                      ),
                    ),
                  ),
                ),
                // 어르신·보호자 화면은 가입한 계정의 역할로 정해진다.
                // 여기서 바꾸는 버튼은 두지 않는다.
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _GuardianRow extends StatelessWidget {
  final GuardianContact guardian;

  /// 보호자가 먼저 청한 연결에 수락(true)·거절(false)로 대답한다.
  final ValueChanged<bool> onAnswer;

  const _GuardianRow({required this.guardian, required this.onAnswer});

  @override
  Widget build(BuildContext context) {
    final waiting = guardian.awaitsMyAnswer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            InitialAvatar(
              name: guardian.name,
              size: 48,
              background: AppColors.bg,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(guardian.label, style: AppText.cardTitle()),
                  Text(
                    waiting
                        ? '함께 보기를 요청했어요'
                        : guardian.phone ?? '약 드신 것과 심장 박동을 볼 수 있어요',
                    style: waiting
                        ? AppText.caption(color: AppColors.point)
                        : AppText.caption(),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (waiting) ...[
          const SizedBox(height: 10),
          // 수락하면 이 분이 복약·심장 박동을 보게 된다. 거절이 옆에 같이 있다.
          Row(
            children: [
              Expanded(
                child: SeniorButton(
                  label: '수락',
                  minHeight: 56,
                  fontSize: 20,
                  onPressed: () => onAnswer(true),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SeniorButton(
                  label: '거절',
                  kind: SeniorButtonKind.secondary,
                  minHeight: 56,
                  fontSize: 20,
                  onPressed: () => onAnswer(false),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
