import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../dashboard/presentation/screens/patient_data.dart';
import '../../../prescription/presentation/screens/prescription_screen.dart';
import '../../application/guardians_provider.dart';

/// 그 어르신 대신 처방전을 찍는 화면을 연다 (프로토타입 80).
Future<void> openGuardianPrescription(
  BuildContext context,
  CarePatient patient,
) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PrescriptionScreen(
        onBehalfOf: patient.title,
        onBehalfOfUserId: patient.patientId,
        onCompleted: (_) => Navigator.of(context).maybePop(),
      ),
    ),
  );
}

/// 보호자 · 어느 분 처방전인가요 (프로토타입 96).
///
/// 대신 넣은 약은 **고른 분에게만** 들어간다. 잘못 고르면 남의 약이 된다.
class GuardianPickPatientScreen extends ConsumerWidget {
  const GuardianPickPatientScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patients =
        ref.watch(careOverviewProvider).valueOrNull?.patients ??
        const <CarePatient>[];

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          SeniorHeader(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SeniorBackButton(onTap: () => Navigator.of(context).pop()),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('보호자 화면 · 대신 찍기', style: AppText.label(size: 17)),
                      Text(
                        '어느 분 처방전인가요?',
                        style: AppText.screenTitle(size: 26),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final patient in patients) ...[
                    SeniorCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 14,
                      ),
                      onTap: () => openGuardianPrescription(context, patient),
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
                                Text(
                                  patient.title,
                                  style: AppText.cardTitle(size: 21),
                                ),
                                if (patient.totalCount > 0)
                                  Text(
                                    '오늘 먹을 약 ${patient.totalCount}번',
                                    style: AppText.caption(size: 17.5),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          const SeniorChevron(),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 14,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '고른 분에게만 들어갑니다',
                          style: AppText.cardTitle(size: 21),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '등록이 끝나면 그 어르신 전화기에 "약을 넣어드렸어요" 알림이 갑니다.',
                          style: AppText.body(size: 18),
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
}
