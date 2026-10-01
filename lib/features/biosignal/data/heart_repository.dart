import '../../../core/network/api_client.dart';
import '../../../core/session/mvp_session.dart';
import '../../medication/domain/medication_models.dart';
import '../domain/heart_data.dart';

/// 저장된 심박 기록을 읽어 온다.
///
/// 화면이 오늘·이번 주·한 달을 따로 부르면 그 사이 날짜가 바뀔 때
/// 서로 다른 기준의 숫자가 한 화면에 놓인다. 그래서 한 번에 받는다.
class HeartRepository {
  HeartRepository({ApiClient? apiClient})
    : _apiClient = apiClient ?? ApiClient();

  final ApiClient _apiClient;

  /// 서버에서 읽어 [HeartData]로 만든다.
  ///
  /// [userId]가 없으면 로그인한 사람의 기록을 읽는다. 보호자가 어르신
  /// 기록을 볼 때는 어르신 id를 넘긴다.
  ///
  /// 못 읽으면 **null**을 돌려준다. 데모 데이터로 조용히 갈아끼우지 않는다 —
  /// 가짜 숫자를 진짜처럼 보여주면 그것대로 판단의 근거가 된다.
  Future<HeartData?> fetch({String? userId}) async {
    final id = (userId ?? MvpSession.userId).trim();
    if (id.isEmpty) return null;
    try {
      final response = await _apiClient.get(
        '/api/v1/users/${Uri.encodeComponent(id)}/biosignal/heart-summary'
        '?include_readings=true&utc_offset_minutes=${DateTime.now().timeZoneOffset.inMinutes}',
      );
      if (response is! Map) return null;
      // An old server or malformed response must not masquerade as no records.
      if (response['readings'] is! List ||
          DateTime.tryParse(response['period_date']?.toString() ?? '') ==
              null) {
        return null;
      }
      return _parse(Map<String, dynamic>.from(response));
    } catch (_) {
      return null;
    }
  }

  HeartData _parse(Map<String, dynamic> json) {
    final today = _pair(json['today']);
    final anomaly = _anomaly(json['anomaly'], today);

    return HeartData(
      readings: [for (final raw in json['readings'] as List) _reading(raw)],
      periodDate: DateTime.parse(json['period_date'] as String),
      today: today,
      // 서버는 오늘 잰 것이 없어도 "저녁 약"을 채워 보낸다. 여기서 또
      // 지어내지 않고, 오늘 값이 없으면 화면이 이 이름을 숨긴다.
      todaySlotLabel: json['today_slot_label']?.toString() ?? '',
      // 못 잰 쪽은 시각도 비운다. "--:--"를 채워 넣지 않는다.
      beforeAt: _clock(json['before_at']),
      afterAt: _clock(json['after_at']),
      week: _week(json['week']),
      month: _month(json['month']),
      streakDays: _int(json['streak_days']) ?? 0,
      bestStreakDays: _int(json['best_streak_days']) ?? 0,
      anomaly: anomaly,
      // 센서 상태는 기록이 아니라 지금 붙어 있는지의 문제라
      // 여기서 말하지 않는다. 화면이 HeartSensor 에서 직접 읽는다.
      sensorConnected: false,
      sensorBattery: null,
      sensorLastReadAt: '',
      notifyGuardian: true,
    );
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }

  static HeartReading _reading(dynamic raw) {
    if (raw is! Map) throw const FormatException('Invalid heart reading');
    final id = _int(raw['id']);
    final bpm = _int(raw['bpm']);
    final at = DateTime.tryParse(raw['measured_at']?.toString() ?? '');
    if (id == null || bpm == null || at == null || !at.isUtc) {
      throw const FormatException('Invalid heart reading');
    }
    return HeartReading(
      id: id,
      bpm: bpm,
      measuredAt: at.toLocal(),
      measurementContext: HeartMeasurementContext.fromValue(
        raw['measurement_context'],
      ),
    );
  }

  /// 서버의 "17:45"를 앱이 늘 쓰는 "오후 5시 45분"으로.
  ///
  /// 어르신 화면은 24시간 표기를 쓰지 않는다. 모양을 모르면 받은 그대로 둔다.
  static String _clock(Object? raw) {
    final text = raw?.toString().trim() ?? '';
    final match = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(text);
    if (match == null) return text;
    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    if (hour > 23 || minute > 59) return text;
    return DoseSlot.absoluteTime(DateTime(2000, 1, 1, hour, minute));
  }

  static HeartPair _pair(Object? raw) {
    if (raw is! Map) return const HeartPair();
    return HeartPair(before: _int(raw['before']), after: _int(raw['after']));
  }

  static List<HeartDay> _week(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is Map)
          HeartDay(entry['weekday']?.toString() ?? '', _pair(entry)),
    ];
  }

  static List<HeartMonthDay> _month(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is Map && _int(entry['day']) != null)
          HeartMonthDay(_int(entry['day'])!, _pair(entry)),
    ];
  }

  static HeartAnomaly? _anomaly(Object? raw, HeartPair today) {
    if (raw is! Map) return null;
    final day = _int(raw['day']);
    final before = _int(raw['before']);
    final after = _int(raw['after']);
    // 셋 중 하나라도 없으면 "이상했던 날"이라고 말하지 않는다.
    if (day == null || before == null || after == null) return null;
    return HeartAnomaly(
      day: day,
      // 서버의 'label'은 "9월 12일"처럼 날짜다. 화면이 날짜를 따로 붙이므로
      // 여기에 넣으면 "9월 12일 9월 12일"이 된다. 때(아침·저녁)만 받는다.
      slotLabel: raw['slot_label']?.toString() ?? '',
      before: before,
      after: after,
    );
  }
}
