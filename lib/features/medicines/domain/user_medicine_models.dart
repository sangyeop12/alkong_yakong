/// 내 약 목록·상세 API 응답 모델.
library;

import 'display_policy.dart';

class TreatmentUse {
  final String title;
  final String description;

  const TreatmentUse({required this.title, this.description = ''});
}

class UserMedicine {
  final String medicineCode;
  final String displayName;
  final String officialProductName;
  final String manufacturer;
  final String ingredientName;
  final String ingredientSummary;
  final String ingredientStrength;
  final String dosageForm;
  final String administrationRoute;
  final String status;
  final String interactionStatus;
  final String? interactionSummary;
  final String interactionRiskLevel;
  final String interactionRiskFactor;
  final String interactionPairLabel;
  final List<String> interactionConflictNames;
  final String amount;
  final String? purposeLabel;
  final String? shortExplanation;
  final String? detailExplanation;
  final String? keyCaution;
  final List<String> keyCautions;
  final List<String> easyPurposes;
  final String? purposeNotice;
  final String? dosage;
  final int? frequencyPerDay;
  final List<String> administrationTimes;
  final String ingredientExplanation;
  final String ingredientHighlight;
  final String approvedUseSummary;
  final List<String> approvedUses;
  final List<String> allApprovedUses;
  final List<TreatmentUse> treatmentUses;
  final String officialUsage;
  final String officialUsageNotice;
  final List<String> askDoctorWhen;
  final List<String> possibleSideEffects;
  final String detailStatus;
  final String detailReviewStatus;
  final String detailSourceName;
  final bool detailSourceVerified;
  final String detailContentGeneratedBy;
  final String detailServedFrom;
  final int detailContentVersion;

  const UserMedicine({
    required this.medicineCode,
    required this.displayName,
    required this.officialProductName,
    this.manufacturer = '',
    required this.ingredientName,
    this.ingredientSummary = '',
    this.ingredientStrength = '',
    this.dosageForm = '',
    this.administrationRoute = '',
    this.status = 'active',
    this.interactionStatus = 'not_checked',
    this.interactionSummary,
    this.interactionRiskLevel = '',
    this.interactionRiskFactor = '',
    this.interactionPairLabel = '',
    this.interactionConflictNames = const [],
    required this.amount,
    this.purposeLabel,
    this.shortExplanation,
    this.detailExplanation,
    this.keyCaution,
    this.keyCautions = const [],
    this.easyPurposes = const [],
    this.purposeNotice,
    this.dosage,
    this.frequencyPerDay,
    this.administrationTimes = const [],
    this.ingredientExplanation = '',
    this.ingredientHighlight = '',
    this.approvedUseSummary = '',
    this.approvedUses = const [],
    this.allApprovedUses = const [],
    this.treatmentUses = const [],
    this.officialUsage = '',
    this.officialUsageNotice = '',
    this.askDoctorWhen = const [],
    this.possibleSideEffects = const [],
    this.detailStatus = 'PENDING',
    this.detailReviewStatus = 'UNAVAILABLE',
    this.detailSourceName = '',
    this.detailSourceVerified = false,
    this.detailContentGeneratedBy = '',
    this.detailServedFrom = '',
    this.detailContentVersion = 0,
  });

  factory UserMedicine.fromJson(Map<String, dynamic> json) {
    final rawShortExplanation = json['short_explanation']?.toString().trim();
    final card = resolveMyMedicineCard(
      medicineCode: json['medicine_code']?.toString(),
      productName: json['product_name']?.toString(),
      displayName: json['display_name']?.toString(),
      ingredient: json['ingredient']?.toString(),
      purposeLabel: json['purpose_label']?.toString(),
      shortExplanation: json['short_explanation']?.toString(),
      easyCategory: json['easy_category']?.toString(),
    );
    return UserMedicine(
      medicineCode: json['medicine_code']?.toString() ?? '',
      displayName: card.name,
      officialProductName:
          json['official_product_name']?.toString() ?? card.name,
      manufacturer: json['manufacturer']?.toString() ?? '',
      ingredientName:
          json['ingredient_name']?.toString() ??
          json['ingredient']?.toString() ??
          '',
      ingredientSummary: json['ingredient_summary']?.toString() ?? '',
      ingredientStrength: json['ingredient_strength']?.toString() ?? '',
      dosageForm: json['dosage_form']?.toString() ?? '',
      administrationRoute: json['administration_route']?.toString() ?? '',
      status: json['status']?.toString() ?? 'active',
      interactionStatus:
          json['interaction_status']?.toString() ?? 'not_checked',
      interactionSummary: json['interaction_summary']?.toString(),
      interactionRiskLevel: json['interaction_risk_level']?.toString() ?? '',
      interactionRiskFactor: json['interaction_risk_factor']?.toString() ?? '',
      interactionPairLabel: json['interaction_pair_label']?.toString() ?? '',
      interactionConflictNames: _stringList(json['interaction_conflict_names']),
      amount: json['amount']?.toString() ?? '',
      purposeLabel: card.purposeLabel,
      shortExplanation: card.spoken,
      // 상세 첫 문장은 홈 목록용 짧은 분류를 재사용하지 않는다.
      // 서버가 검토된 상세 문장을 주지 않으면 이 줄 자체를 숨긴다.
      detailExplanation: (rawShortExplanation?.isNotEmpty ?? false)
          ? rawShortExplanation
          : null,
      keyCaution: json['key_caution']?.toString(),
      keyCautions: _stringList(json['key_cautions']),
      easyPurposes: _stringList(json['easy_purposes']),
      purposeNotice: json['purpose_notice']?.toString(),
      dosage: json['dosage']?.toString(),
      frequencyPerDay: _intOrNull(json['frequency_per_day']),
      administrationTimes: _stringList(json['administration_times']),
      ingredientExplanation: json['ingredient_explanation']?.toString() ?? '',
      // 서버가 숫자나 이상한 값을 주면 강조하지 않는다. 엉뚱한 곳이
      // 굵어지면 어르신은 그 말이 중요한 줄 안다.
      ingredientHighlight: json['ingredient_highlight'] is String
          ? (json['ingredient_highlight'] as String)
          : '',
      approvedUseSummary: json['approved_use_summary']?.toString() ?? '',
      approvedUses: _stringList(json['approved_uses']),
      allApprovedUses: _stringList(json['all_approved_uses']),
      treatmentUses: _treatmentUseList(json['treatment_uses']),
      officialUsage: json['official_usage']?.toString() ?? '',
      officialUsageNotice: json['official_usage_notice']?.toString() ?? '',
      askDoctorWhen: _stringList(json['ask_doctor_when']),
      possibleSideEffects: _stringList(json['possible_side_effects']),
      detailStatus: json['detail_status']?.toString() ?? 'PENDING',
      detailReviewStatus:
          json['detail_review_status']?.toString() ?? 'UNAVAILABLE',
      detailSourceName: json['detail_source_name']?.toString() ?? '',
      detailSourceVerified: json['detail_source_verified'] == true,
      detailContentGeneratedBy:
          json['detail_content_generated_by']?.toString() ?? '',
      detailServedFrom: json['detail_served_from']?.toString() ?? '',
      detailContentVersion: _intOrNull(json['detail_content_version']) ?? 0,
    );
  }

  String? get effect => homePurposeCaption(purposeLabel);

  String? get cardSpoken => cardSpokenOf(shortExplanation);

  String? get detailSpoken => detailSpokenOf(detailExplanation);

  bool get hasReviewedDetail =>
      detailReviewStatus.toUpperCase() == 'REVIEWED' &&
      (ingredientExplanation.trim().isNotEmpty ||
          approvedUseSummary.trim().isNotEmpty ||
          approvedUses.isNotEmpty ||
          allApprovedUses.isNotEmpty);

  bool get hasDetailContent =>
      ingredientExplanation.trim().isNotEmpty ||
      approvedUseSummary.trim().isNotEmpty ||
      approvedUses.isNotEmpty ||
      allApprovedUses.isNotEmpty ||
      treatmentUses.isNotEmpty;

  String get ingredientLabel {
    final summary = ingredientSummary.trim().isNotEmpty
        ? ingredientSummary.trim()
        : compactIngredientSummary(ingredientName);
    return [
      summary,
      ingredientStrength.trim(),
    ].where((value) => value.isNotEmpty).join(' · ');
  }

  String get frequencyLabel {
    final freq = frequencyPerDay;
    if (freq == null || freq <= 0) return '복용 횟수 정보 없음';
    return '하루 $freq번';
  }

  String get dosageLabel {
    final take = amount.trim();
    if (take.isNotEmpty) return take;
    final raw = dosage?.trim();
    if (raw != null && raw.isNotEmpty) return raw;
    return '용량 정보 없음';
  }

  String get doseAction {
    final value = '$dosageForm $administrationRoute';
    if (value.contains('점안')) return '눈에 넣는';
    if (value.contains('연고') || value.contains('크림') || value.contains('외용')) {
      return '바르는';
    }
    if (value.contains('패치') || value.contains('패취')) return '붙이는';
    if (value.contains('흡입')) return '들이마시는';
    return '먹는';
  }

  static List<String> _stringList(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .map((value) {
          if (value is Map) {
            return value['easy_label']?.toString() ??
                value['short_sentence']?.toString() ??
                '';
          }
          return value.toString();
        })
        .where((value) => value.trim().isNotEmpty)
        .toList();
  }

  static List<TreatmentUse> _treatmentUseList(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map(
          (item) => TreatmentUse(
            title: item['title']?.toString().trim() ?? '',
            description: item['description']?.toString().trim() ?? '',
          ),
        )
        .where((item) => item.title.isNotEmpty)
        .take(3)
        .toList();
  }

  static int? _intOrNull(dynamic raw) {
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '');
  }
}
