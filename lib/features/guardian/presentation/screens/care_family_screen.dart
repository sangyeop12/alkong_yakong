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

/// 36 · 보호자 · 돌보는 분 목록.
///
/// 서버에 연결된 어르신만 보여준다. 연결을 요청한 분은 어르신이 수락할 때까지
/// "수락을 기다리는 중"으로 따로 둔다 — 동의 없이 남의 복약을 들여다보는 길을
/// 만들지 않는다.
class CareFamilyScreen extends ConsumerWidget {
  /// 어르신 카드를 눌렀을 때.
  final ValueChanged<CarePatient> onOpenPatient;

  /// 헤더의 종 단추. 알림 화면을 연다.
  final VoidCallback? onOpenAlerts;

  /// 요청을 보낼 곳. 없으면 이 화면이 하나 만들어 쓴다.
  final GuardianRepository? repository;

  const CareFamilyScreen({
    super.key,
    required this.onOpenPatient,
    this.onOpenAlerts,
    this.repository,
  });

  GuardianRepository get _repository => repository ?? GuardianRepository();

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    PendingInvite invite,
  ) async {
    final id = invite.id;
    if (id == null) return;
    try {
      await _repository.remove(id);
      ref.invalidate(careOverviewProvider);
    } on ApiException catch (error) {
      if (context.mounted) {
        showSeniorSnackbar(context, error.message, error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(careOverviewProvider);
    final data = overview.valueOrNull;
    final patients = data?.patients ?? const <CarePatient>[];
    final pending = data?.pending ?? const <PendingInvite>[];
    final needAttention = patients.where((p) => p.needsAttention).toList();

    return Column(
      children: [
        // 제목은 한 줄로 둔다. 어르신 화면의 상단바와 같은 높이로 서야
        // 탭을 옮길 때 바가 들썩이지 않는다. 보호자인지는 하단 탭 라벨
        // (돌보는 분 · 정보)이 이미 말해 준다.
        SeniorTitleHeader(
          title: data == null ? '돌보는 분' : '돌보는 분 ${patients.length}명',
          trailing: onOpenAlerts == null
              ? null
              : _AlertBell(count: needAttention.length, onTap: onOpenAlerts!),
        ),
        Expanded(
          // 당겨서 새로고침을 두지 않는다. 돌보는 분이 몇 분 안 되면 목록이
          // 화면에 다 들어가는데, 새로고침을 살리려면 늘 끌리게 만들어야 해
          // 스크롤할 것이 없는데도 화면이 들썩였다. 목록은 화면에 들어오면
          // 움직이지 않고, 길어지면 그때부터 평소대로 스크롤된다.
          child: SingleChildScrollView(
            // 아래 여백이 28이면 카드가 다 들어가고도 여백 때문에 몇 px이
            // 넘쳐 목록이 헛돈다. 카드끼리 이미 12씩 띄우고 있어 16이면
            // 탭바와 충분히 떨어진다.
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (data == null && overview.isLoading)
                  const _InfoCard(text: '불러오는 중이에요')
                else if (data == null)
                  _InfoCard(
                    text: '돌보는 분 목록을 불러오지 못했어요',
                    actionLabel: '다시 불러오기',
                    onAction: () => ref.invalidate(careOverviewProvider),
                  )
                else if (patients.isEmpty && pending.isEmpty)
                  const _InfoCard(
                    text:
                        '아직 연결된 어르신이 없어요. 정보 → 돌보는 분 관리에서 '
                        '어르신 전화번호로 연결을 요청해 주세요.',
                  ),
                if (needAttention.isNotEmpty) ...[
                  _AttentionBanner(patients: needAttention),
                  const SizedBox(height: 12),
                ],
                for (int i = 0; i < patients.length; i++) ...[
                  if (i > 0) const SizedBox(height: 12),
                  _PatientCard(
                    patient: patients[i],
                    onTap: () => onOpenPatient(patients[i]),
                  ),
                ],
                for (final invite in pending) ...[
                  const SizedBox(height: 12),
                  _PendingCard(
                    invite: invite,
                    onCancel: () => _cancel(context, ref, invite),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 헤더 오른쪽 종 단추. 확인이 필요한 분 수를 빨간 점에 적는다.
class _AlertBell extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const _AlertBell({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: count == 0 ? '알림' : '알림 $count건',
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: onTap,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.bg,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(
                  TablerIcons.bell,
                  size: 26,
                  color: AppColors.textPrimary,
                ),
              ),
              if (count > 0)
                Positioned(
                  right: -6,
                  top: -6,
                  child: Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: AppColors.danger,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '$count',
                      style: AppText.cardTitle(size: 16, color: Colors.white),
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

class _InfoCard extends StatelessWidget {
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _InfoCard({required this.text, this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) {
    return SeniorCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(text, style: AppText.body(size: 18)),
          if (actionLabel != null) ...[
            const SizedBox(height: 12),
            SeniorButton(
              label: actionLabel!,
              kind: SeniorButtonKind.secondary,
              minHeight: 58,
              fontSize: 20,
              onPressed: onAction,
            ),
          ],
        ],
      ),
    );
  }
}

/// 먼저 확인할 분. 색이 아니라 **이름**을 앞세운다.
class _AttentionBanner extends StatelessWidget {
  final List<CarePatient> patients;

  const _AttentionBanner({required this.patients});

  @override
  Widget build(BuildContext context) {
    return AccentCard(
      accent: AppColors.danger,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '먼저 확인할 분',
            style: AppText.cardTitle(size: 18, color: AppColors.danger),
          ),
          const SizedBox(height: 6),
          Text(
            patients
                .map((p) => p.relation.isEmpty ? p.name : p.relation)
                .join(', '),
            style: AppText.cardTitle(size: 20),
          ),
        ],
      ),
    );
  }
}

class _PatientCard extends StatelessWidget {
  final CarePatient patient;
  final VoidCallback onTap;

  const _PatientCard({required this.patient, required this.onTap});

  String get _status {
    if (patient.totalCount == 0) return '오늘 드실 약이 등록돼 있지 않아요';
    if (patient.needsAttention) return '${patient.nextDoseLabel} 약이 남아 있어요';
    return '오늘 ${_spokenCount(patient.totalCount)} 다 드셨어요';
  }

  /// "세 번"처럼 읽어 준다. 숫자보다 말이 먼저 들어온다.
  static String _spokenCount(int count) {
    const words = ['', '한 번', '두 번', '세 번', '네 번', '다섯 번'];
    if (count >= 1 && count < words.length) return words[count];
    return '$count번';
  }

  @override
  Widget build(BuildContext context) {
    return SeniorCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
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
                    Text(
                      '오늘 복약 ${patient.takenCount} / ${patient.totalCount}'
                      '${patient.heartRate == null ? '' : ' · 심박수 ${patient.heartRate}'}',
                      style: AppText.caption(size: 17.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const SeniorChevron(),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.sunken,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(_status, style: AppText.label(size: 18)),
          ),
        ],
      ),
    );
  }
}

/// 아직 수락하지 않은 요청. 점선 테두리로 "아직 아님"을 눈에 보이게 한다.
class _PendingCard extends StatelessWidget {
  final PendingInvite invite;
  final VoidCallback onCancel;

  const _PendingCard({required this.invite, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final title = invite.relation.isEmpty
        ? invite.name
        : '${invite.relation} · ${invite.name}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.strongLine, width: 2),
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
                Text(title, style: AppText.cardTitle(size: 20)),
                Text(
                  '${invite.phone} · 수락을 기다리는 중',
                  style: AppText.caption(size: 17),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SeniorTextButton(
            label: '취소',
            expand: false,
            fontSize: 18,
            color: AppColors.textTertiary,
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}
