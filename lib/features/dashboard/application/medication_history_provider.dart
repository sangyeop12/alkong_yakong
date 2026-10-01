import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_config.dart';
import '../../../core/session/mvp_session.dart';
import '../../medication/domain/medication_models.dart';

/// 하루치 복약 기록. 시간대 단위로 센다.
@immutable
class DayAdherence {
  final DateTime date;
  final int taken;
  final int total;

  /// 다 드시지 못한 시간대 이름 ("점심").
  final List<String> missedSlots;

  const DayAdherence({
    required this.date,
    required this.taken,
    required this.total,
    this.missedSlots = const [],
  });

  bool get complete => total > 0 && taken >= total;
}

DateTime dateOnly(DateTime time) => DateTime(time.year, time.month, time.day);

/// 로그인한 사람의 기록.
///
/// 기록 탭의 한 주·한 달과 달력이 모두 이 값을 쓴다. 기록이 없는 날은
/// 목록에 없다 — "다 드셨다"로도 "빠뜨렸다"로도 채우지 않는다.
final medicationHistoryProvider = FutureProvider<Map<DateTime, DayAdherence>>(
  (ref) => fetchMedicationHistory(MvpSession.userId),
);

/// 보호자가 보는 어르신의 기록.
final patientHistoryProvider =
    FutureProvider.family<Map<DateTime, DayAdherence>, String>(
      (ref, userId) => fetchMedicationHistory(userId),
    );

/// 이번 달 1일(이번 주 월요일이 더 이르면 그날)부터 오늘까지.
Future<Map<DateTime, DayAdherence>> fetchMedicationHistory(
  String userId, {
  ApiClient? apiClient,
}) async {
  final id = userId.trim();
  if (id.isEmpty) return const {};

  final today = dateOnly(DateTime.now());
  final monday = today.subtract(Duration(days: today.weekday - 1));
  final sunday = monday.add(const Duration(days: 6));
  final monthStart = DateTime(today.year, today.month);
  final start = monday.isBefore(monthStart) ? monday : monthStart;
  // 이번 주 남은 약 있는 날을 기록 칸에 그리려면 오늘 이후도 받는다.
  final end = sunday.isAfter(today) ? sunday : today;

  String day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  final response =
      await (apiClient ?? ApiClient(baseUrl: ApiConfig.localFeatureBaseUrl))
          .get(
            '/api/v1/users/${Uri.encodeComponent(id)}/medication-history'
            '?start=${day(start)}&end=${day(end)}',
          );
  final rows = response is Map ? response['days'] : null;
  if (rows is! List) return const {};

  final result = <DateTime, DayAdherence>{};
  for (final row in rows) {
    if (row is! Map) continue;
    final date = DateTime.tryParse(row['date']?.toString() ?? '');
    if (date == null) continue;
    final missed = row['missed_slots'];
    result[dateOnly(date)] = DayAdherence(
      date: dateOnly(date),
      taken: (row['taken'] as num?)?.toInt() ?? 0,
      total: (row['total'] as num?)?.toInt() ?? 0,
      missedSlots: missed is List
          ? [for (final slot in missed) slot.toString()]
          : const [],
    );
  }
  return result;
}

/// OCR 직후 달력 API가 비어도, 방금 확인한 약 있는 날로 칸을 켠다.
/// 이미 서버에 있는 날은 숫자를 덮지 않는다. 먹었어요로 바꾸지 않는다.
Map<DateTime, DayAdherence> mergeCachedScheduleDates(
  Map<DateTime, DayAdherence> history,
) {
  final cached = MvpSession.latestScheduleDates;
  if (cached.isEmpty) return history;

  final result = Map<DateTime, DayAdherence>.from(history);
  final today = dateOnly(DateTime.now());
  for (final raw in cached) {
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) continue;
    final date = dateOnly(parsed);
    if (date.isBefore(today)) continue;
    result.putIfAbsent(
      date,
      () => DayAdherence(date: date, taken: 0, total: 1),
    );
  }
  return result;
}

/// 오늘은 서버보다 이 전화기의 상태가 앞선다. 방금 누른 "먹었어요"를 반영한다.
DayAdherence todayAdherence(TodayMedication today) => DayAdherence(
  date: dateOnly(DateTime.now()),
  taken: today.takenCount,
  total: today.doses.length,
  missedSlots: [
    for (final dose in today.doses)
      if (!dose.taken) dose.slot.label,
  ],
);
