import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/mode/app_mode.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/recovery_view.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../application/user_medicines_controller.dart';
import '../../domain/display_policy.dart';
import '../../domain/user_medicine_models.dart';

/// 내 약 한 종류 상세 — 서버 쉬운말·주의·복용 정보.
class DrugDetailScreen extends ConsumerStatefulWidget {
  final String medicineCode;

  const DrugDetailScreen({super.key, required this.medicineCode});

  @override
  ConsumerState<DrugDetailScreen> createState() => _DrugDetailScreenState();
}

class _DrugDetailScreenState extends ConsumerState<DrugDetailScreen> {
  UserMedicine? _medicine;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final med = await ref
          .read(userMedicinesProvider.notifier)
          .loadDetail(widget.medicineCode);
      if (!mounted) return;
      setState(() {
        _medicine = med;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final easyMode = ref.watch(appModeProvider).isEasy;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          SeniorBackHeader(
            title: '약 자세히',
            onBack: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? RecoveryView(
                    title: '약 정보를\n불러오지 못했어요',
                    reassurance: '잠시 연결이 끊겼을 수 있어요. ',
                    reassuranceEmphasis: '고장이 아니니 걱정하지 마세요.',
                    steps: const ['다시 시도해 보세요'],
                    actionLabel: '다시 불러오기',
                    onAction: _load,
                    stillWorksTitle: '지금도 할 수 있는 것',
                    stillWorksBody: '오늘 홈에서 복약 기록은 그대로 쓸 수 있어요.',
                  )
                : _DetailBody(medicine: _medicine!, easyMode: easyMode),
          ),
        ],
      ),
    );
  }
}

class _DetailBody extends StatelessWidget {
  final UserMedicine medicine;
  final bool easyMode;

  const _DetailBody({required this.medicine, required this.easyMode});

  @override
  Widget build(BuildContext context) {
    final ingredients = ingredientParts(medicine.ingredientName);
    final seenUses = <String>{};
    final extraOfficialUses = medicine.allApprovedUses.where((purpose) {
      final normalized = purpose.trim();
      return normalized.isNotEmpty &&
          normalized != medicine.approvedUseSummary.trim() &&
          !medicine.approvedUses.any((shown) => shown.trim() == normalized) &&
          // 같은 줄이 두 번 오면 한 번만 읽게 둔다.
          seenUses.add(normalized);
    }).toList();
    final cautions = <String>[
      if ((medicine.keyCaution ?? '').trim().isNotEmpty) medicine.keyCaution!,
      ...medicine.keyCautions.where(
        (c) => c.trim().isNotEmpty && c != medicine.keyCaution,
      ),
    ].where((text) => _isPersonCaution(text)).take(3).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SeniorCard(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  medicine.displayName,
                  style: AppText.screenTitle(size: 26),
                ),
                if (medicine.manufacturer.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    '제조사: ${medicine.manufacturer}',
                    style: AppText.caption(
                      size: 18,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
                if (ingredients.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text('주성분', style: AppText.label(size: 19)),
                  const SizedBox(height: 4),
                  for (int index = 0; index < ingredients.length; index++)
                    Text(
                      '${ingredients.length > 1 ? '· ' : ''}${ingredients[index]}${index == 0 && medicine.ingredientStrength.trim().isNotEmpty ? ' · ${medicine.ingredientStrength.trim()}' : ''}',
                      style: AppText.body(
                        size: 20,
                        color: AppColors.textSecondary,
                      ),
                    ),
                ],
                if (medicine.detailSpoken != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    medicine.detailSpoken!,
                    style: AppText.body(size: 21, color: AppColors.textBody),
                  ),
                ],
                if (medicine.easyPurposes.any(isCardPurposeLabel)) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final purpose in medicine.easyPurposes)
                        if (isCardPurposeLabel(purpose))
                          _TagChip(label: purpose),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (medicine.hasDetailContent) ...[
            if (medicine.ingredientExplanation.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              SeniorCard(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    IconTitle(
                      icon: Icons.science_outlined,
                      text: easyMode ? '이 성분은 어떤 역할을 하나요?' : '주성분 설명',
                      style: AppText.cardTitle(size: 22),
                    ),
                    const SizedBox(height: 12),
                    _EmphasizedBodyText(
                      text: medicine.ingredientExplanation,
                      highlight: medicine.ingredientHighlight,
                      ingredient: medicine.ingredientName,
                      fallbackHighlight: medicine.approvedUseSummary,
                    ),
                  ],
                ),
              ),
            ],
            if (medicine.treatmentUses.isNotEmpty ||
                medicine.approvedUseSummary.trim().isNotEmpty ||
                medicine.approvedUses.isNotEmpty) ...[
              const SizedBox(height: 12),
              SeniorCard(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    IconTitle(
                      icon: Icons.medical_information_outlined,
                      text: '어떤 치료에 쓰이나요?',
                      style: AppText.cardTitle(size: 22),
                    ),
                    if (medicine.treatmentUses.isNotEmpty)
                      for (final use in medicine.treatmentUses) ...[
                        const SizedBox(height: 12),
                        Text(
                          '· ${use.title}',
                          style: AppText.body(
                            size: 20,
                            color: AppColors.detailEmphasis,
                          ).copyWith(fontWeight: FontWeight.w800),
                        ),
                        if (use.description.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Padding(
                            padding: const EdgeInsets.only(left: 14),
                            child: Text(
                              use.description,
                              style: AppText.body(size: 20),
                            ),
                          ),
                        ],
                      ]
                    else ...[
                      if (medicine.approvedUseSummary.trim().isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          medicine.approvedUseSummary,
                          style: AppText.body(size: 20),
                        ),
                      ],
                      for (final purpose in medicine.approvedUses) ...[
                        const SizedBox(height: 8),
                        Text('· $purpose', style: AppText.body(size: 20)),
                      ],
                    ],
                    const SizedBox(height: 10),
                    Text(
                      '실제 처방 이유는 의료진에게 확인해 주세요.',
                      style: AppText.caption(
                        size: 18,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (extraOfficialUses.isNotEmpty) ...[
              const SizedBox(height: 12),
              SeniorCard(
                padding: EdgeInsets.zero,
                child: Theme(
                  data: Theme.of(
                    context,
                  ).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 6,
                    ),
                    childrenPadding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
                    title: Text(
                      easyMode ? '더 자세한 사용 목적 보기' : '전체 허가 목적',
                      style: AppText.cardTitle(size: 22),
                    ),
                    children: [
                      for (final purpose in extraOfficialUses) ...[
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '· $purpose',
                            style: AppText.body(size: 20),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ] else ...[
            const SizedBox(height: 12),
            SeniorCard(
              padding: const EdgeInsets.all(20),
              child: Text(
                _detailStatusMessage(medicine.detailStatus),
                style: AppText.body(size: 20, color: AppColors.textSecondary),
              ),
            ),
          ],
          if (cautions.isNotEmpty) ...[
            const SizedBox(height: 12),
            SeniorCard(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconTitle(
                    icon: TablerIcons.alert_triangle,
                    color: AppColors.danger,
                    text: '꼭 기억해 주세요',
                    style: AppText.cardTitle(size: 22, color: AppColors.danger),
                  ),
                  const SizedBox(height: 12),
                  for (final caution in cautions) ...[
                    Text(
                      '· $caution',
                      style: AppText.body(size: 20, color: AppColors.textBody),
                    ),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ],
          if (medicine.interactionStatus == 'risk_found' &&
              (medicine.interactionSummary ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            SeniorCard(
              padding: const EdgeInsets.all(22),
              borderColor: AppColors.danger,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconTitle(
                    icon: TablerIcons.alert_triangle,
                    color: AppColors.danger,
                    text: '함께먹기 주의가 있어요',
                    style: AppText.cardTitle(size: 22, color: AppColors.danger),
                  ),
                  const SizedBox(height: 10),
                  if (medicine.interactionPairLabel.trim().isNotEmpty) ...[
                    Text(
                      medicine.interactionPairLabel,
                      style: AppText.body(size: 20),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Text(
                    medicine.interactionSummary!,
                    style: AppText.body(size: 20),
                  ),
                  if (medicine.interactionRiskFactor.trim().isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      '성분 위험요소: ${medicine.interactionRiskFactor}',
                      style: AppText.label(size: 19),
                    ),
                  ],
                  if (!medicine.interactionSummary!.contains('확인해')) ...[
                    const SizedBox(height: 8),
                    Text(
                      '약국이나 병원에 한 번 확인해 주세요.',
                      style: AppText.label(size: 19, color: AppColors.danger),
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          SeniorCard(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconTitle(
                  icon: TablerIcons.clock,
                  text: '내가 처방받은 복용 방법',
                  style: AppText.cardTitle(size: 22),
                ),
                const SizedBox(height: 12),
                Text(
                  '한 번에 ${medicine.doseAction} 양 ${medicine.dosageLabel}',
                  style: AppText.body(size: 21),
                ),
                const SizedBox(height: 6),
                Text(medicine.frequencyLabel, style: AppText.body(size: 21)),
                if (medicine.administrationTimes.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    '시간: ${medicine.administrationTimes.join(' · ')}',
                    style: AppText.caption(size: 18),
                  ),
                ],
              ],
            ),
          ),
          if (medicine.officialUsage.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            SeniorCard(
              padding: EdgeInsets.zero,
              child: Theme(
                data: Theme.of(
                  context,
                ).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 6,
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
                  title: Text(
                    easyMode ? '공식 복용 안내 보기' : '제품 공식 용법·용량',
                    style: AppText.cardTitle(size: 22),
                  ),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        medicine.officialUsageNotice.trim().isNotEmpty
                            ? medicine.officialUsageNotice
                            : '제품 설명서의 일반적인 사용법이에요. 실제로는 처방전과 의료진의 안내대로 복용하세요.',
                        style: AppText.caption(
                          size: 18,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        formatOfficialUsage(medicine.officialUsage),
                        style: AppText.body(size: 20),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (medicine.askDoctorWhen.isNotEmpty) ...[
            const SizedBox(height: 12),
            SeniorCard(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconTitle(
                    icon: Icons.contact_support_outlined,
                    text: '언제 의료진에게 알려야 하나요?',
                    style: AppText.cardTitle(size: 22),
                  ),
                  const SizedBox(height: 12),
                  for (final situation in medicine.askDoctorWhen) ...[
                    Text('· $situation', style: AppText.body(size: 20)),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ],
          if (medicine.detailSourceName.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            SeniorCard(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('정보 출처', style: AppText.label(size: 19)),
                  const SizedBox(height: 6),
                  Text(
                    '식약처 의약품 허가정보',
                    style: AppText.caption(
                      size: 18,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if ((medicine.purposeNotice ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            SeniorCard(
              padding: const EdgeInsets.all(20),
              child: Text(
                medicine.purposeNotice!,
                style: AppText.caption(
                  size: 18,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static bool _isPersonCaution(String text) {
    final value = text.trim();
    if (value.isEmpty) return false;
    if (value.contains('사용상의주의')) return false;
    if (value.contains('투여하지 말')) return false;
    if (value.contains('신중히 투여')) return false;
    return true;
  }

  static String _detailStatusMessage(String status) {
    return switch (status.toUpperCase()) {
      'FAILED' => '자세한 설명을 불러오지 못했지만 제품 기본 정보는 볼 수 있어요.',
      'OUTDATED' => '기존 안전 정보는 볼 수 있어요. 최신 공식 정보로 갱신 중이에요.',
      'NEEDS_REVIEW' => '공식 정보에서 안전하게 정리한 기본 설명을 보여드려요.',
      _ => '현재 확인할 수 있는 제품 기본 정보를 보여드려요.',
    };
  }
}

class _EmphasizedBodyText extends StatelessWidget {
  final String text;
  final String highlight;
  final String ingredient;
  final String fallbackHighlight;

  const _EmphasizedBodyText({
    required this.text,
    required this.highlight,
    required this.ingredient,
    required this.fallbackHighlight,
  });

  @override
  Widget build(BuildContext context) {
    final bodyStyle = AppText.body(size: 20);
    final effect = _effectTarget();
    final ranges = <_EmphasisRange>[];
    final ingredientTarget = ingredient.trim();
    final ingredientStart = ingredientTarget.isEmpty
        ? -1
        : text.indexOf(ingredientTarget);
    if (ingredientStart >= 0) {
      ranges.add(
        _EmphasisRange(
          ingredientStart,
          ingredientStart + ingredientTarget.length,
          bodyStyle.copyWith(fontWeight: FontWeight.w800),
        ),
      );
    }
    final effectStart = effect.isEmpty ? -1 : text.indexOf(effect);
    if (effectStart >= 0) {
      ranges.add(
        _EmphasisRange(
          effectStart,
          effectStart + effect.length,
          bodyStyle.copyWith(
            color: AppColors.detailEmphasis,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
    }
    ranges.sort((a, b) => a.start.compareTo(b.start));
    if (ranges.isEmpty) {
      return Text(text, style: bodyStyle);
    }
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final range in ranges) {
      if (range.start < cursor) continue;
      if (range.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, range.start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(range.start, range.end),
          style: range.style,
        ),
      );
      cursor = range.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return Text.rich(TextSpan(style: bodyStyle, children: spans));
  }

  /// 본문 전체를 강조하면 강조가 아니다. 그런 값은 버린다.
  bool _wholeBody(String value) => value.trim() == text.trim();

  String _effectTarget() {
    final reviewed = highlight.trim();
    if (reviewed.isNotEmpty &&
        !_wholeBody(reviewed) &&
        text.contains(reviewed)) {
      return reviewed;
    }
    var fallback = fallbackHighlight.trim();
    if (fallback.startsWith('이 약은 ')) fallback = fallback.substring(5);
    fallback = fallback.replaceFirst(
      RegExp(r'\s*(사용해요|사용돼요|사용될 수 있어요|도움을 줘요)\.?$'),
      '',
    );
    return fallback.isNotEmpty &&
            !_wholeBody(fallback) &&
            text.contains(fallback)
        ? fallback
        : '';
  }
}

class _EmphasisRange {
  final int start;
  final int end;
  final TextStyle style;

  const _EmphasisRange(this.start, this.end, this.style);
}

class _TagChip extends StatelessWidget {
  final String label;

  const _TagChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.pointTint,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        label,
        style: AppText.label(size: 18, color: AppColors.point),
      ),
    );
  }
}
