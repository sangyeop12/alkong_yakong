import '../../../core/network/api_client.dart';
import '../../dashboard/presentation/screens/patient_data.dart';

/// 보호자에게 온 알림.
///
/// 서버가 준 종류를 화면이 아는 다섯 갈래로 옮긴다. 모르는 종류가 와도
/// **버리지 않는다** — 안 보여주면 보호자는 그런 일이 없었다고 믿는다.
class AlertRepository {
  AlertRepository({ApiClient? apiClient})
    : _apiClient = apiClient ?? ApiClient();

  final ApiClient _apiClient;

  /// 못 읽으면 null. 데모 알림으로 갈아끼우지 않는다.
  Future<List<AlertItem>?> fetch(String userId) async {
    final id = userId.trim();
    if (id.isEmpty) return null;
    try {
      final response = await _apiClient.get(
        '/api/v1/users/${Uri.encodeComponent(id)}/notifications',
      );
      if (response is! List) return null;
      return [
        for (final raw in response)
          if (raw is Map) _toAlert(Map<String, dynamic>.from(raw)),
      ];
    } catch (_) {
      return null;
    }
  }

  AlertItem _toAlert(Map<String, dynamic> json) {
    final type = json['notification_type']?.toString() ?? '';
    return AlertItem(
      type: _kindOf(type),
      title: json['title']?.toString() ?? _titleOf(type),
      desc: json['message']?.toString() ?? '',
      time: _time(json['sent_at'] ?? json['created_at']),
      tappable: false,
    );
  }

  /// 서버 종류를 화면이 아는 갈래로.
  static String _kindOf(String type) {
    final upper = type.toUpperCase();
    if (upper.contains('ABNORMAL') || upper.contains('HEART')) return 'alert';
    if (upper.contains('MISS')) return 'miss';
    if (upper.contains('REFILL') || upper.contains('EXPIRE')) return 'refill';
    if (upper.contains('PRESCRIPTION')) return 'prescription';
    if (upper.contains('SHARE') || upper.contains('DUR')) return 'shared';
    if (upper.contains('TAKEN') || upper.contains('REMIND')) return 'done';
    // 모르는 종류는 지난 것으로 둔다. 회색으로 뒤에 놓되 지우지 않는다.
    return 'past';
  }

  static String _titleOf(String type) => switch (_kindOf(type)) {
    'alert' => '심장 박동이 빨라요',
    'miss' => '약을 안 드셨어요',
    'refill' => '약이 떨어졌어요',
    'prescription' => '새 처방전',
    'shared' => '어르신이 보냈어요',
    'done' => '약 다 드셨어요',
    _ => '알림',
  };

  /// **상대시간을 쓰지 않는다.** "15분 전"은 언제인지 다시 계산하게 만든다.
  static String _time(Object? raw) {
    final parsed = DateTime.tryParse(raw?.toString() ?? '');
    if (parsed == null) return '';
    final now = DateTime.now();
    final sameDay =
        parsed.year == now.year &&
        parsed.month == now.month &&
        parsed.day == now.day;
    final clock =
        '${parsed.hour.toString().padLeft(2, '0')}:'
        '${parsed.minute.toString().padLeft(2, '0')}';
    return sameDay ? clock : '${parsed.month}월 ${parsed.day}일 $clock';
  }
}
