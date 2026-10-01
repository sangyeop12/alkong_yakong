/// 복약 도메인 모델.
///
/// 문구 규칙: 의료 용어를 쓰지 않는다.
/// 복약 완료 → "다 드셨어요", 미복약 → "아직 안 드셨어요".
library;

import '../../medicines/domain/display_policy.dart';

/// 하루 세 번의 복약 시간대.
enum DoseSlot {
  morning('아침', 8),
  lunch('점심', 12),
  dinner('저녁', 18);

  const DoseSlot(this.label, this.hour);

  /// "아침" / "점심" / "저녁".
  final String label;

  /// 24시간제 기준 시각.
  final int hour;

  /// "아침 8시" / "저녁 6시" — 화면에 그대로 쓰는 큰 시각 문구.
  String get spokenTime {
    final display = hour > 12 ? hour - 12 : hour;
    return '$label $display시';
  }

  /// "오후 6시 2분" 형태의 절대시간. **상대시간("15분 전")은 쓰지 않는다.**
  static String absoluteTime(DateTime time) {
    final isAfternoon = time.hour >= 12;
    final hour12 = time.hour % 12 == 0 ? 12 : time.hour % 12;
    final period = isAfternoon ? '오후' : '오전';
    return '$period $hour12시 ${time.minute}분';
  }

  DateTime todayAt(DateTime now) =>
      DateTime(now.year, now.month, now.day, hour);
}

/// 약 한 가지.
class Medicine {
  /// 화면 제목으로 쓰는 허가 제품명(기존 코드 호환 필드).
  final String ingredient;

  /// 실제 주성분. 제품명과 섞지 않는다.
  final String? ingredientName;

  /// 서버가 계산한 카드용 복합 성분 요약.
  final String? ingredientSummary;

  /// 주성분 함량.
  final String? ingredientStrength;

  /// "1알".
  final String amount;

  /// 생김새 — "흰색 동그란 알약".
  /// 3a는 약 사진을 쓰지 않으므로 화면에 크게 띄우지 않고,
  /// 음성 안내([5d])와 스크린리더 설명에만 쓴다.
  final String? appearance;

  /// 어르신용 짧은 분류. 홈·OCR 카드에는 이 값을 쓴다.
  final String? easyCategory;

  /// 허가 효능을 묶은 쉬운 목적 이름 — 예: "가려움 완화 · 불안·긴장 완화".
  final String? purposeLabel;

  /// 환자 카드에서 읽을 쉬운 한 문장.
  final String? shortExplanation;

  /// 공식 주의사항에서 고른 가장 중요한 한 문장.
  final String? keyCaution;

  /// 식약처 허가 효능 원문. 홈 카드에는 쓰지 않는다.
  final String? efficacy;

  /// 오늘 스케줄 id — 「먹었어요」 서버 기록용.
  final int? scheduleId;

  /// 상세 화면 연결용 공식 약 코드.
  final String? medicineCode;

  /// 처방에 적힌 하루 복용 횟수.
  final int? frequencyPerDay;

  const Medicine({
    required this.ingredient,
    required this.amount,
    this.ingredientName,
    this.ingredientSummary,
    this.ingredientStrength,
    this.appearance,
    this.easyCategory,
    this.purposeLabel,
    this.shortExplanation,
    this.keyCaution,
    this.efficacy,
    this.scheduleId,
    this.medicineCode,
    this.frequencyPerDay,
  });

  /// 홈·OCR 카드에 보여 줄 쉬운 한 줄. 허가 원문·폴백 문장은 쓰지 않는다.
  String? get cardSpoken {
    return cardSpokenOf(shortExplanation) ??
        cardSpokenOf(easyCategory) ??
        cardSpokenOf(efficacy);
  }

  /// 화면에 보여 줄 약 이름. 허가명에서 중복 주성분 괄호만 숨긴다.
  String get displayName {
    final name = compactProductName(ingredient, ingredient: ingredientName);
    return name.isEmpty ? '약' : name;
  }

  String? get ingredientLabel {
    final name = (ingredientSummary?.trim().isNotEmpty ?? false)
        ? ingredientSummary!.trim()
        : compactIngredientSummary(ingredientName);
    final strength = ingredientStrength?.trim() ?? '';
    if (name.isEmpty && strength.isEmpty) return null;
    return [name, strength].where((value) => value.isNotEmpty).join(' · ');
  }

  /// 메인 홈 카드의 짧은 분류. 증상 키워드 나열은 쓰지 않는다.
  String? get effect => homePurposeCaption(purposeLabel);

  /// 메인 홈에서 DrugInfo 찾기에 쓰던 키. 서버 약 코드를 쓴다.
  String? get key => medicineCode;

  /// 음성으로 읽어줄 때의 한 줄 — "메트포르민 500mg, 흰색 동그란 알약 1알".
  String get spoken {
    final base = appearance == null
        ? '$displayName $amount'
        : '$displayName, $appearance $amount';
    return [
      base,
      purposeLabel,
      cardSpoken,
      keyCaution,
    ].where((value) => value != null && value.trim().isNotEmpty).join(', ');
  }
}

/// 한 복약 시간대에 붙는 심박수 측정.
///
/// 없으면 null — **행을 그리지 않는다.** 재지 않은 시간대에 가짜 값을
/// 채우면 그 숫자가 그대로 판단의 근거가 된다.
class DoseHeartCheck {
  /// 약 먹기 전.
  final int before;

  /// 약 먹은 뒤.
  final int after;

  final DateTime measuredAt;

  const DoseHeartCheck({
    required this.before,
    required this.after,
    required this.measuredAt,
  });

  /// 먹은 뒤 몇 회 낮아졌는지. 올라갔으면 음수.
  int get drop => before - after;

  /// "평소와 비슷" / "조금 낮아졌어요" / "조금 빨라요"
  String get phrase {
    // 빠른 쪽을 먼저 본다. 낮아진 폭보다 먼저 알려야 할 사실이다.
    if (after >= 80) return '조금 빨라요';
    if (drop >= 5) return '조금 낮아졌어요';
    return '평소와 비슷';
  }

  /// 빠르면 화면이 붉게 짚어 준다.
  bool get isFast => after >= 80;
}

/// 한 시간대의 복약 상태.
class DoseEntry {
  final DoseSlot slot;
  final List<Medicine> medicines;
  final bool taken;

  /// 기록된 절대 시각. 되돌리면 다시 null이 된다.
  final DateTime? takenAt;

  /// "30분 뒤에 다시" 를 눌러 사다리가 밀린 시각.
  final DateTime? snoozedUntil;

  /// 이 시간대에 잰 심박수. 안 쟀으면 null.
  final DoseHeartCheck? heartCheck;

  const DoseEntry({
    required this.slot,
    required this.medicines,
    this.taken = false,
    this.takenAt,
    this.snoozedUntil,
    this.heartCheck,
  });

  /// "두 알" — 개수를 한글로 읽어준다.
  String get countPhrase {
    const words = ['', '한', '두', '세', '네', '다섯', '여섯'];
    final count = medicines.length;
    if (count < words.length) return '${words[count]} 알';
    return '$count알';
  }

  DoseEntry copyWith({
    bool? taken,
    DateTime? takenAt,
    DateTime? snoozedUntil,
    DoseHeartCheck? heartCheck,
    bool clearTakenAt = false,
    bool clearSnooze = false,
  }) {
    return DoseEntry(
      slot: slot,
      medicines: medicines,
      taken: taken ?? this.taken,
      takenAt: clearTakenAt ? null : (takenAt ?? this.takenAt),
      snoozedUntil: clearSnooze ? null : (snoozedUntil ?? this.snoozedUntil),
      heartCheck: heartCheck ?? this.heartCheck,
    );
  }
}

/// "먹었어요"를 눌렀을 때의 결과.
enum DoseCheckOutcome {
  /// 정상 기록.
  recorded,

  /// 이미 기록된 시간대 — 5f 중복 복용 차단 시트를 띄운다.
  alreadyTaken,

  /// 복약 시각에서 4시간 이상 지남 — 지연 복약 시트를 띄운다.
  tooLate,
}

/// 오늘 하루 전체 상태.
class TodayMedication {
  final List<DoseEntry> doses;

  /// 함께 보는 가족. 이름만 쓰고 관계는 앞에 붙인다 — "딸 지안".
  /// 등록된 가족이 없으면 서버는 "보호자"·"가족"을 준다.
  final String guardianRelation;
  final String guardianName;

  /// 가장 최근에 잰 심박수. 잰 적이 없으면 null — 예시 숫자로 채우지 않는다.
  final int? heartRate;
  final bool? heartRateNormal;

  /// 가장 먼저 끝나는 처방이 며칠 남았는지. 끝나는 날을 모르면 null.
  final int? daysLeft;

  /// 그 처방을 받은 날과 총 일수. 약 떨어짐 안내에 쓴다.
  final DateTime? courseStartedOn;
  final int? courseTotalDays;
  final String? interactionAlert;
  final List<InteractionPriorityCard> interactionCards;

  const TodayMedication({
    required this.doses,
    required this.guardianRelation,
    required this.guardianName,
    this.heartRate,
    this.heartRateNormal,
    this.daysLeft,
    this.courseStartedOn,
    this.courseTotalDays,
    this.interactionAlert,
    this.interactionCards = const [],
  });

  /// 아직 아무것도 읽지 못했을 때.
  static const empty = TodayMedication(
    doses: [],
    guardianRelation: '보호자',
    guardianName: '가족',
  );

  bool get hasGuardian {
    final name = guardianName.trim();
    return name.isNotEmpty &&
        !(name == '가족' && guardianRelation.trim() == '보호자');
  }

  /// "딸 지안 님". 등록된 가족이 없으면 "가족".
  String get guardianTitle => hasGuardian
      ? '${guardianRelation.trim()} ${guardianName.trim()} 님'.trim()
      : '가족';

  /// 함께먹기 주의 건수. 카드가 없고 문장만 있으면 한 건으로 센다.
  int get interactionCount {
    if (interactionCards.isNotEmpty) return interactionCards.length;
    return (interactionAlert ?? '').trim().isEmpty ? 0 : 1;
  }

  int get takenCount => doses.where((d) => d.taken).length;

  bool get allTaken => takenCount == doses.length;

  /// 아직 안 드신 첫 시간대. 다 드셨으면 null.
  DoseEntry? get nextDose {
    for (final dose in doses) {
      if (!dose.taken) return dose;
    }
    return null;
  }

  DoseEntry doseOf(DoseSlot slot) {
    for (final dose in doses) {
      if (dose.slot == slot) return dose;
    }
    return DoseEntry(slot: slot, medicines: const []);
  }

  /// "아침·점심 다 드셨어요" — 완료 요약 카드 문구.
  String get takenSummary {
    final done = doses.where((d) => d.taken).map((d) => d.slot.label).toList();
    if (done.isEmpty) return '아직 드신 약이 없어요';
    if (allTaken) return '오늘 약 다 드셨어요';
    return '${done.join('·')} 다 드셨어요';
  }

  /// "약 3일치 남았어요". 남은 날을 모르면 빈 문자열.
  String get daysLeftPhrase {
    final left = daysLeft;
    if (left == null) return '';
    return left <= 0 ? '오늘이 마지막이에요' : '이 처방 $left일치 남았어요';
  }

  TodayMedication copyWith({
    List<DoseEntry>? doses,
    int? daysLeft,
    String? interactionAlert,
    List<InteractionPriorityCard>? interactionCards,
  }) => TodayMedication(
    doses: doses ?? this.doses,
    guardianRelation: guardianRelation,
    guardianName: guardianName,
    heartRate: heartRate,
    heartRateNormal: heartRateNormal,
    daysLeft: daysLeft ?? this.daysLeft,
    courseStartedOn: courseStartedOn,
    courseTotalDays: courseTotalDays,
    interactionAlert: interactionAlert ?? this.interactionAlert,
    interactionCards: interactionCards ?? this.interactionCards,
  );
}

class InteractionPriorityCard {
  final String nameA;
  final String nameB;
  final String? codeA;
  final String? codeB;
  final String reason;
  final String riskFactor;

  const InteractionPriorityCard({
    required this.nameA,
    required this.nameB,
    required this.reason,
    this.codeA,
    this.codeB,
    this.riskFactor = '',
  });

  factory InteractionPriorityCard.fromJson(Map<String, dynamic> json) {
    return InteractionPriorityCard(
      nameA: json['name_a']?.toString() ?? '',
      nameB: json['name_b']?.toString() ?? '',
      codeA: json['code_a']?.toString(),
      codeB: json['code_b']?.toString(),
      reason: json['reason']?.toString() ?? '함께 먹을 때 주의가 필요해요',
      riskFactor: json['risk_factor']?.toString() ?? '',
    );
  }
}
