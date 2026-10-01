import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_config.dart';
import '../../../core/session/mvp_session.dart';
import '../../medicines/domain/display_policy.dart';
import '../../reminder/domain/reminder_ladder.dart';
import '../domain/medication_models.dart';

/// 복약 시각에서 이만큼 지나면 지연 복약으로 본다.
const Duration kLateDoseThreshold = Duration(hours: 4);

final reminderSchedulerProvider = Provider<ReminderScheduler>(
  (ref) => InMemoryReminderScheduler(),
);

final medicationProvider =
    NotifierProvider<MedicationController, TodayMedication>(
      MedicationController.new,
    );

/// 보호자가 보는 어르신의 오늘 복약. 기록은 어르신 전화기에서만 바뀐다.
final patientTodayProvider = FutureProvider.family<TodayMedication, String>((
  ref,
  userId,
) async {
  final response = await ApiClient(
    baseUrl: ApiConfig.localFeatureBaseUrl,
  ).get('/api/v1/users/${Uri.encodeComponent(userId)}/today-medicines');
  if (response is! Map) {
    throw const ApiException('오늘 복약을 받지 못했어요.');
  }
  return MedicationController.parse(Map<String, dynamic>.from(response));
});

/// 보호자 호칭. 넘겨받은 값이 없으면 서버에 등록된 가족으로 채운다.
String resolveGuardianTitle(BuildContext context, String? given) {
  final trimmed = given?.trim() ?? '';
  if (trimmed.isNotEmpty) return trimmed;
  // 화면이 Riverpod 밖에서 열릴 수도 있다. 그때는 호칭을 지어내지 않고
  // 비워 둔다 — 없는 가족 이름을 만들어 내는 편이 더 나쁘다.
  try {
    return ProviderScope.containerOf(
      context,
      listen: false,
    ).read(medicationProvider).guardianTitle;
  } on StateError {
    return '';
  }
}

/// 오늘 복약 상태를 들고 있는 컨트롤러.
///
/// 서버 응답을 우선한다. 서버가 빈 목록을 주면 데모약을 치운다.
/// (빈 응답인데 데모를 남기면 가짜 약이 실약처럼 보임)
/// 네트워크 실패 시에만 기존(또는 데모) 상태를 유지한다.
class MedicationController extends Notifier<TodayMedication> {
  final ApiClient _api;

  MedicationController({ApiClient? apiClient})
    : _api = apiClient ?? ApiClient(baseUrl: ApiConfig.localFeatureBaseUrl);

  @override
  TodayMedication build() {
    Future.microtask(refreshFromServer);
    return const TodayMedication(
      doses: [],
      guardianRelation: '보호자',
      guardianName: '가족',
    );
  }

  Future<void> refreshFromServer({bool throwOnError = false}) async {
    try {
      final userId = Uri.encodeComponent(MvpSession.userId);
      final response = await _api.get('/api/v1/users/$userId/today-medicines');
      if (response is! Map || response['doses'] is! List) {
        throw const ApiException('오늘 복약을 받지 못했어요.');
      }
      final parsed = parse(Map<String, dynamic>.from(response));
      // 서버가 정상 응답했으면 비어 있어도 그대로 반영 (데모 유지 금지)
      state = parsed;
    } catch (_) {
      if (throwOnError) rethrow;
      // 서버 불가면 현재 상태(최초엔 데모) 유지
    }
  }

  /// `/today-medicines` 응답을 화면 상태로. 보호자 화면도 같은 규칙으로 읽는다.
  static TodayMedication parse(Map<String, dynamic> data) {
    final rawDoses = data['doses'];
    final doses = <DoseEntry>[];
    if (rawDoses is List) {
      for (final raw in rawDoses) {
        if (raw is! Map) continue;
        final slot = _slotOf(raw['slot']?.toString());
        if (slot == null) continue;
        final meds = <Medicine>[];
        final rawMeds = raw['medicines'];
        if (rawMeds is List) {
          for (final m in rawMeds) {
            if (m is! Map) continue;
            final card = resolveMyMedicineCard(
              medicineCode: m['medicine_code']?.toString(),
              productName: m['product_name']?.toString(),
              displayName: m['display_name']?.toString(),
              ingredient: m['ingredient']?.toString(),
              purposeLabel: m['purpose_label']?.toString(),
              shortExplanation: m['short_explanation']?.toString(),
              easyCategory: m['easy_category']?.toString(),
            );
            if (isMockDrugInfoName(card.name)) continue;
            final scheduleRaw = m['schedule_id'];
            final scheduleId = scheduleRaw is num
                ? scheduleRaw.toInt()
                : int.tryParse(scheduleRaw?.toString() ?? '');
            meds.add(
              Medicine(
                ingredient: card.name,
                ingredientName:
                    m['ingredient_name']?.toString() ??
                    m['ingredient']?.toString(),
                ingredientSummary: m['ingredient_summary']?.toString(),
                ingredientStrength: m['ingredient_strength']?.toString(),
                amount: m['amount']?.toString() ?? '',
                easyCategory: card.spoken,
                purposeLabel: card.purposeLabel,
                shortExplanation: card.spoken,
                keyCaution: m['key_caution']?.toString(),
                efficacy: null,
                scheduleId: scheduleId,
                medicineCode: m['medicine_code']?.toString(),
                frequencyPerDay: (m['frequency_per_day'] as num?)?.toInt(),
              ),
            );
          }
        }
        if (meds.isEmpty) continue;
        doses.add(
          DoseEntry(slot: slot, medicines: meds, taken: raw['taken'] == true),
        );
      }
    }
    return TodayMedication(
      doses: doses,
      guardianRelation: data['guardian_relation']?.toString() ?? '보호자',
      guardianName: data['guardian_name']?.toString() ?? '가족',
      heartRate: (data['latest_heart_rate'] as num?)?.toInt(),
      heartRateNormal: data['latest_heart_rate_normal'] as bool?,
      daysLeft: (data['days_left'] as num?)?.toInt(),
      courseStartedOn: DateTime.tryParse(
        data['course_started_on']?.toString() ?? '',
      ),
      courseTotalDays: (data['course_total_days'] as num?)?.toInt(),
      interactionAlert: data['interaction_alert']?.toString(),
      interactionCards: _interactionCards(data['interaction_cards']),
    );
  }

  static List<InteractionPriorityCard> _interactionCards(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final row in raw)
        if (row is Map)
          InteractionPriorityCard.fromJson(Map<String, dynamic>.from(row)),
    ];
  }

  static DoseSlot? _slotOf(String? raw) {
    switch ((raw ?? '').toLowerCase()) {
      case 'morning':
        return DoseSlot.morning;
      case 'lunch':
        return DoseSlot.lunch;
      case 'dinner':
        return DoseSlot.dinner;
      default:
        return null;
    }
  }

  final Set<DoseSlot> _guardianNotified = <DoseSlot>{};
  final Map<DoseSlot, int> _snoozeCount = <DoseSlot, int>{};
  bool _refillAsked = false;

  /// 처방이 오늘 끝나고, 언제 받은 몇 일치인지 알 때만 묻는다.
  bool get shouldAskRefill =>
      state.daysLeft == 0 &&
      state.courseStartedOn != null &&
      state.courseTotalDays != null &&
      !_refillAsked;

  void markRefillAsked() => _refillAsked = true;

  void refill({int days = 21}) {
    _refillAsked = false;
    state = state.copyWith(daysLeft: days);
  }

  bool guardianNotifiedFor(DoseSlot slot) => _guardianNotified.contains(slot);

  Future<DoseCheckOutcome> take(DoseSlot slot, {DateTime? now}) async {
    final at = now ?? DateTime.now();
    final dose = state.doseOf(slot);

    if (dose.taken) return DoseCheckOutcome.alreadyTaken;

    final scheduled = slot.todayAt(at);
    if (at.difference(scheduled) > kLateDoseThreshold) {
      return DoseCheckOutcome.tooLate;
    }

    await _record(slot, at);
    return DoseCheckOutcome.recorded;
  }

  Future<void> takeAnyway(DoseSlot slot, {DateTime? now}) {
    return _record(slot, now ?? DateTime.now());
  }

  Future<void> _record(DoseSlot slot, DateTime at) async {
    await _postTakenLogs(slot);
    state = state.copyWith(
      doses: [
        for (final dose in state.doses)
          if (dose.slot == slot)
            dose.copyWith(taken: true, takenAt: at, clearSnooze: true)
          else
            dose,
      ],
    );
    ref.read(reminderSchedulerProvider).cancelSlot(slot);
    _snoozeCount.remove(slot);
    _guardianNotified.add(slot);
  }

  Future<void> _postTakenLogs(DoseSlot slot) async {
    final dose = state.doseOf(slot);
    final userId = MvpSession.userId.trim();
    if (userId.isEmpty) {
      throw const ApiException('복약 완료를 저장할 사용자 정보가 없습니다.');
    }
    var posted = false;
    for (final med in dose.medicines) {
      final scheduleId = med.scheduleId;
      if (scheduleId == null || scheduleId <= 0) continue;
      await _api.post(
        '/api/v1/medication-logs',
        body: {'user_id': userId, 'schedule_id': scheduleId},
      );
      posted = true;
    }
    if (!posted) {
      throw const ApiException('복약 일정 정보를 확인할 수 없습니다.');
    }
  }

  void undo(DoseSlot slot) {
    state = state.copyWith(
      doses: [
        for (final dose in state.doses)
          if (dose.slot == slot)
            dose.copyWith(taken: false, clearTakenAt: true)
          else
            dose,
      ],
    );
    _guardianNotified.remove(slot);
    _scheduleLadder(slot);
  }

  DateTime snooze(DoseSlot slot, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final count = (_snoozeCount[slot] ?? 0) + 1;
    _snoozeCount[slot] = count;

    final until = slot.todayAt(at).add(ReminderLadder.snoozeInterval * count);
    state = state.copyWith(
      doses: [
        for (final dose in state.doses)
          if (dose.slot == slot) dose.copyWith(snoozedUntil: until) else dose,
      ],
    );
    _scheduleLadder(slot, now: at);
    return until;
  }

  void _scheduleLadder(DoseSlot slot, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final scheduler = ref.read(reminderSchedulerProvider);
    scheduler.cancelSlot(slot);
    scheduler.schedule(
      ReminderLadder.planFor(
        slot,
        slot.todayAt(at),
        snoozeCount: _snoozeCount[slot] ?? 0,
      ),
    );
  }
}
