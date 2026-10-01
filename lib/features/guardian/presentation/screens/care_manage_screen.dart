import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_feedback.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../dashboard/presentation/screens/patient_data.dart';
import '../../application/guardians_provider.dart';
import '../../data/guardian_repository.dart';
import '../widgets/add_care_sheet.dart';
import 'care_patient_screen.dart';

/// 보호자 · 돌보는 분 관리 (프로토타입 90).
///
/// 목록 화면이 "오늘 어떠신가"를 본다면, 여기는 "누구를 돌보는가"를 고친다.
class CareManageScreen extends ConsumerWidget {
  const CareManageScreen({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final draft = await showAddCareSheet(context);
    if (draft == null || !context.mounted) return;

    final result = await GuardianRepository().requestLink(
      relation: draft.relation,
      phone: draft.phone,
    );
    if (!context.mounted) return;
    if (!result.isSent) {
      showSeniorSnackbar(context, result.error ?? '연결을 요청하지 못했어요', error: true);
      return;
    }
    ref.invalidate(careOverviewProvider);
    final name = result.invite!.name.isEmpty ? draft.name : result.invite!.name;
    showSeniorSnackbar(context, '$name 님에게 연결을 요청했어요');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(careOverviewProvider);
    final data = overview.valueOrNull;
    final patients = data?.patients ?? const <CarePatient>[];
    final pending = data?.pending ?? const <PendingInvite>[];

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const SeniorBackHeader(title: '돌보는 분 관리', alignStart: true),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 18,
                    ),
                    child: Text(
                      '한 분씩 따로 설정돼요',
                      style: AppText.cardTitle(size: 21),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (patients.isNotEmpty)
                    SeniorCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 4,
                      ),
                      child: Column(
                        children: [
                          for (int i = 0; i < patients.length; i++) ...[
                            if (i > 0) const SeniorDivider(),
                            _ManageRow(
                              patient: patients[i],
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      CarePatientScreen(patient: patients[i]),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    )
                  else
                    SeniorCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 18,
                      ),
                      child: Text(
                        overview.isLoading
                            ? '불러오는 중이에요'
                            : '아직 연결된 어르신이 없어요. 아래에서 어르신 전화번호로 연결을 요청해 주세요.',
                        style: AppText.body(size: 18),
                      ),
                    ),
                  for (final invite in pending) ...[
                    const SizedBox(height: 12),
                    SeniorCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 18,
                      ),
                      child: Row(
                        children: [
                          const ExcludeSemantics(
                            child: Icon(
                              TablerIcons.hourglass_high,
                              size: 26,
                              color: AppColors.textTertiary,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  invite.relation.isEmpty
                                      ? invite.name
                                      : '${invite.relation} · ${invite.name}',
                                  style: AppText.cardTitle(size: 20),
                                ),
                                Text(
                                  '${invite.phone} · 수락을 기다리는 중',
                                  style: AppText.caption(size: 17),
                                ),
                              ],
                            ),
                          ),
                          SeniorTextButton(
                            label: '취소',
                            expand: false,
                            fontSize: 18,
                            color: AppColors.textTertiary,
                            onPressed: () => _cancel(context, ref, invite),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: SeniorButton(
                label: '돌보는 분 추가하기',
                icon: TablerIcons.user_plus,
                minHeight: 70,
                onPressed: () => _add(context, ref),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    PendingInvite invite,
  ) async {
    final id = invite.id;
    if (id == null) return;
    try {
      await GuardianRepository().remove(id);
      ref.invalidate(careOverviewProvider);
    } on ApiException catch (error) {
      if (context.mounted) {
        showSeniorSnackbar(context, error.message, error: true);
      }
    }
  }
}

/// 어머니 · 김복자 / 79세 · 고혈압 · 당뇨.
class _ManageRow extends StatelessWidget {
  final CarePatient patient;
  final VoidCallback onTap;

  const _ManageRow({required this.patient, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final age = patient.age;
    final line = [if (age != null) '$age세'].join(' · ');

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            InitialAvatar(
              name: patient.name,
              size: 56,
              background: AppColors.pointTint,
              foreground: AppColors.point,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(patient.title, style: AppText.cardTitle(size: 21)),
                  if (line.isNotEmpty)
                    Text(line, style: AppText.caption(size: 17.5)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const SeniorChevron(),
          ],
        ),
      ),
    );
  }
}
