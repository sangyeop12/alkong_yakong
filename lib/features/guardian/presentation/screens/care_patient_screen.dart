import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../dashboard/presentation/screens/patient_data.dart';
import '../../../medicines/application/user_medicines_controller.dart';
import '../../../medicines/domain/user_medicine_models.dart';
import '../../../profile/domain/user_profile.dart';

String? illnessHistoryLabel(List<String> illnesses, bool? legacyFlag) {
  if (illnesses.isNotEmpty) return illnesses.join(', ');
  return switch (legacyFlag) {
    true => '있으세요',
    false => '없어요',
    null => null,
  };
}

/// 그 어르신의 몸 이야기를 가져온다. 못 가져오면 null.
final carePatientProfileProvider = FutureProvider.family<UserProfile?, String>((
  ref,
  patientId,
) async {
  if (patientId.trim().isEmpty) return null;
  try {
    final response = await ApiClient().get(
      '/api/v1/users/${Uri.encodeComponent(patientId)}',
    );
    if (response is! Map) return null;
    return UserProfile.fromJson(Map<String, dynamic>.from(response));
  } catch (_) {
    return null;
  }
});

/// 보호자 · 어르신 한 분 (프로토타입 91 · 92).
///
/// 대신 처방전을 넣을 때 조심할 것을 맨 위에 둔다.
class CarePatientScreen extends ConsumerWidget {
  final CarePatient patient;

  const CarePatientScreen({super.key, required this.patient});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref
        .watch(carePatientProfileProvider(patient.patientId))
        .valueOrNull;
    final allergies = profile?.allergies ?? const <String>[];
    final medicines = ref.watch(patientMedicinesProvider(patient.patientId));
    final diseases = profile?.diseases ?? const <String>[];

    String? sizeLine() {
      final height = profile?.heightCm;
      final weight = profile?.weightKg;
      if (height == null && weight == null) return null;
      return [
        if (height != null) '${height.toStringAsFixed(0)}cm',
        if (weight != null) '${weight.toStringAsFixed(0)}kg',
      ].join(' · ');
    }

    String? birthLine() {
      final birth = profile?.birthDate;
      if (birth == null) return null;
      return '${birth.year}년 ${birth.month}월 ${birth.day}일';
    }

    String? habitLine() {
      final smoking = profile?.smoking;
      final drinking = profile?.drinking;
      if (smoking == null && drinking == null) return null;
      return [
        if (smoking != null) '담배 $smoking',
        if (drinking != null) '술 $drinking',
      ].join(' · ');
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          SeniorBackHeader(title: patient.title, alignStart: true),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (allergies.isNotEmpty) ...[
                    _WarnCard(text: '${allergies.join(' · ')} 알레르기가 있어요'),
                    const SizedBox(height: 12),
                  ],
                  _MedicineListCard(medicines: medicines),
                  const SizedBox(height: 12),
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 4,
                    ),
                    child: Column(
                      children: [
                        _FactRow(
                          label: '연세',
                          value: patient.age == null ? null : '${patient.age}세',
                        ),
                        const SeniorDivider(),
                        _FactRow(label: '생년월일', value: birthLine()),
                        const SeniorDivider(),
                        _FactRow(
                          label: '성별',
                          value: switch (profile?.gender) {
                            'M' => '남자',
                            'F' => '여자',
                            _ => null,
                          },
                        ),
                        const SeniorDivider(),
                        _FactRow(label: '키 · 몸무게', value: sizeLine()),
                        const SeniorDivider(),
                        _FactRow(label: '혈액형', value: profile?.bloodType),
                        const SeniorDivider(),
                        _FactRow(label: '연락처', value: patient.phone),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 14,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('지금 앓고 있는 병', style: AppText.label(size: 18)),
                        const SizedBox(height: 12),
                        if (diseases.isEmpty)
                          Text('아직 받은 내용이 없어요', style: AppText.body(size: 18))
                        else
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              for (final disease in diseases)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.pointTint,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Text(
                                    disease,
                                    style: AppText.cardTitle(
                                      size: 19,
                                      color: AppColors.point,
                                    ),
                                  ),
                                ),
                            ],
                          ),
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
                        const SeniorDivider(),
                        _FactRow(
                          label: '과거에 앓았던 병',
                          value: illnessHistoryLabel(
                            profile?.pastIllnesses ?? const [],
                            profile?.pastHistory,
                          ),
                        ),
                        _FactRow(
                          label: '가족 병력',
                          value: illnessHistoryLabel(
                            profile?.familyIllnesses ?? const [],
                            profile?.familyHistory,
                          ),
                        ),
                        const SeniorDivider(),
                        _FactRow(label: '담배 · 술', value: habitLine()),
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

/// 약을 드릴 때 조심할 것. 빨간 줄이 선 흰 카드.
class _WarnCard extends StatelessWidget {
  final String text;

  const _WarnCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return AccentCard(
      accent: AppColors.danger,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '약을 드릴 때 조심할 것',
            style: AppText.cardTitle(size: 18, color: AppColors.danger),
          ),
          const SizedBox(height: 6),
          Text(text, style: AppText.emphasis(size: 23)),
          const SizedBox(height: 6),
          Text(
            '새 처방전을 대신 넣을 때 이 약이 들어 있으면 화면이 먼저 알려드려요.',
            style: AppText.body(size: 18),
          ),
        ],
      ),
    );
  }
}

/// 왼쪽에 항목, 오른쪽에 값. 모르는 값은 "아직 받지 못했어요".
class _FactRow extends StatelessWidget {
  final String label;
  final String? value;

  const _FactRow({required this.label, this.value});

  @override
  Widget build(BuildContext context) {
    final text = (value ?? '').trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          Expanded(child: Text(label, style: AppText.label(size: 19))),
          const SizedBox(width: 14),
          Flexible(
            child: Text(
              text.isEmpty ? '아직 받지 못했어요' : text,
              textAlign: TextAlign.end,
              style: text.isEmpty
                  ? AppText.body(size: 18, color: AppColors.textTertiary)
                  : AppText.cardTitle(size: 20),
            ),
          ),
        ],
      ),
    );
  }
}

/// 지금 드시는 약. 대신 처방전을 넣기 전에 무엇이 이미 들어가 있는지
/// 알아야 같은 약을 두 번 넣지 않는다.
class _MedicineListCard extends StatelessWidget {
  final AsyncValue<List<UserMedicine>> medicines;

  const _MedicineListCard({required this.medicines});

  @override
  Widget build(BuildContext context) {
    return SeniorCard(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('지금 드시는 약', style: AppText.cardTitle(size: 21)),
          const SizedBox(height: 12),
          ...medicines.when(
            loading: () => [Text('불러오는 중이에요', style: AppText.body(size: 18))],
            // 못 읽었으면 못 읽었다고 말한다. 빈 목록으로 두면 드시는 약이
            // 없는 줄 알고 같은 약을 또 넣는다.
            error: (_, _) => [
              Text(
                '약 목록을 불러오지 못했어요',
                style: AppText.body(size: 18, color: AppColors.danger),
              ),
            ],
            data: (list) {
              final active = list.where((m) => m.status == 'active').toList();
              if (active.isEmpty) {
                return [Text('등록된 약이 없어요', style: AppText.body(size: 18))];
              }
              return [
                for (int i = 0; i < active.length; i++) ...[
                  if (i > 0) const SeniorDivider(),
                  _MedicineLine(medicine: active[i]),
                ],
              ];
            },
          ),
        ],
      ),
    );
  }
}

class _MedicineLine extends StatelessWidget {
  final UserMedicine medicine;

  const _MedicineLine({required this.medicine});

  @override
  Widget build(BuildContext context) {
    final slots = medicine.administrationTimes
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(medicine.displayName, style: AppText.cardTitle(size: 20)),
          if (medicine.amount.trim().isNotEmpty || slots.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              [
                if (medicine.amount.trim().isNotEmpty) medicine.amount.trim(),
                if (slots.isNotEmpty) slots.join(' · '),
              ].join(' · '),
              style: AppText.caption(size: 17.5),
            ),
          ],
        ],
      ),
    );
  }
}
