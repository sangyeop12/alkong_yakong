abstract final class MvpSession {
  static const String _definedUserId = String.fromEnvironment('USER_ID');

  /// 서버 오늘약 API용. dart-define 없으면 체험 사용자.
  static String userId = _definedUserId.isNotEmpty
      ? _definedUserId
      : 'mvp-user';
  static String medicineCode = '';
  static List<Map<String, dynamic>> latestOcrItems = <Map<String, dynamic>>[];
  static DateTime? latestOcrRegisteredAt;

  /// 방금 등록한 처방전. 약 있는 날 달력이 이 아이디만 본다.
  static String? latestPrescriptionId;

  /// 방금 등록에서 확인한 약 있는 날 (YYYY-MM-DD). 달력 API가 없어도 칸을 그린다.
  static Set<String> latestScheduleDates = <String>{};

  static void rememberPrescriptionSchedules({
    String? prescriptionId,
    dynamic confirmResponse,
    List<Map<String, dynamic>>? ocrItems,
  }) {
    final id = prescriptionId?.trim() ?? '';
    if (id.isNotEmpty) latestPrescriptionId = id;
    final dates = <String>{};
    if (confirmResponse is Map) {
      final items = confirmResponse['items'];
      if (items is List) {
        for (final item in items) {
          if (item is! Map) continue;
          final schedules = item['schedules'];
          if (schedules is! List) continue;
          for (final row in schedules) {
            if (row is! Map) continue;
            final day = row['scheduled_date']?.toString().trim() ?? '';
            if (day.isNotEmpty) dates.add(day);
          }
        }
      }
    }
    if (dates.isEmpty) {
      final source = ocrItems ?? latestOcrItems;
      final today = DateTime.now();
      final start = DateTime(today.year, today.month, today.day);
      for (final item in source) {
        final duration = int.tryParse('${item['duration_days'] ?? ''}');
        if (duration == null || duration < 1) continue;
        final frequency = int.tryParse('${item['frequency_per_day'] ?? ''}');
        final times = item['administration_times'];
        final hasTimes =
            (frequency != null && frequency >= 1) ||
            (times is List && times.isNotEmpty);
        if (!hasTimes) continue;
        for (var offset = 0; offset < duration; offset++) {
          final day = start.add(Duration(days: offset));
          dates.add(
            '${day.year.toString().padLeft(4, '0')}-'
            '${day.month.toString().padLeft(2, '0')}-'
            '${day.day.toString().padLeft(2, '0')}',
          );
        }
      }
    }
    latestScheduleDates = dates;
  }

  /// 임부금기 DUR용. 회원가입·프로필에서 갱신.
  static bool? isPregnant;
}
