/// 보호자 화면이 쓰는 모델.
/// 모두 서버 `/api/v1/guardians/accounts/{id}/patients` 응답에서 만든다.
/// 위치: lib/features/dashboard/presentation/screens/patient_data.dart
library;

/// 보호자가 돌보는 어르신 한 분의 오늘 현황.
class CarePatient {
  /// 연결 한 건의 id. 연결 해제에 쓴다.
  final String linkId;
  final String patientId;
  final String name;

  /// 보호자가 부르는 호칭 ("어머니"). 모르면 빈 문자열.
  final String relation;
  final String? phone;
  final int? age;

  final int takenCount;
  final int totalCount;

  /// 아직 안 드신 첫 시간대 ("저녁 약"). 다 드셨거나 약이 없으면 null.
  final String? nextDoseLabel;
  final List<CareSlot> slots;

  /// 가장 최근에 잰 심박수. 잰 적이 없으면 null.
  final int? heartRate;
  final bool? heartRateNormal;

  /// 최근 7일 복약률. 기록이 없으면 null.
  final int? weekRate;
  final List<ActivityItem> activities;

  const CarePatient({
    required this.linkId,
    required this.patientId,
    required this.name,
    this.relation = '',
    this.phone,
    this.age,
    this.takenCount = 0,
    this.totalCount = 0,
    this.nextDoseLabel,
    this.slots = const [],
    this.heartRate,
    this.heartRateNormal,
    this.weekRate,
    this.activities = const [],
  });

  factory CarePatient.fromJson(Map<String, dynamic> json) {
    int? number(dynamic value) => (value as num?)?.toInt();
    String? text(dynamic value) {
      final trimmed = value?.toString().trim() ?? '';
      return trimmed.isEmpty ? null : trimmed;
    }

    final slots = json['slots'];
    final activities = json['activities'];
    return CarePatient(
      linkId: text(json['link_id']) ?? '',
      patientId: text(json['patient_id']) ?? '',
      name: text(json['name']) ?? '',
      relation: text(json['relation']) ?? '',
      phone: text(json['phone']),
      age: number(json['age']),
      takenCount: number(json['taken_count']) ?? 0,
      totalCount: number(json['total_count']) ?? 0,
      nextDoseLabel: text(json['next_dose_label']),
      slots: [
        if (slots is List)
          for (final slot in slots)
            if (slot is Map)
              CareSlot(
                slot['label']?.toString() ?? '',
                slot['taken'] == true,
                time: slot['taken_at']?.toString() ?? '',
              ),
      ],
      heartRate: number(json['heart_rate']),
      heartRateNormal: json['heart_rate_normal'] as bool?,
      weekRate: number(json['week_rate']),
      activities: [
        if (activities is List)
          for (final item in activities)
            if (item is Map)
              ActivityItem(
                item['text']?.toString() ?? '',
                item['time']?.toString() ?? '',
              ),
      ],
    );
  }

  /// "어머니 · 김복자". 호칭을 모르면 이름만.
  String get title => relation.isEmpty ? name : '$relation · $name';

  /// 오늘 아직 기록이 오지 않은 약이 있는지.
  bool get needsAttention => nextDoseLabel != null;
}

/// 오늘 한 시간대.
class CareSlot {
  final String label;
  final bool taken;

  /// 어르신이 직접 누른 시각 — "08:10". 아직 안 드셨거나 기록이 없으면 빈 글자.
  /// 없는 시각을 지어내지 않는다. 빈 글자면 화면이 시각 자리를 비운다.
  final String time;

  const CareSlot(this.label, this.taken, {this.time = ''});
}

/// 보호자 한 사람이 보는 전체 — 연결된 분과 수락을 기다리는 요청.
class CareOverview {
  final List<CarePatient> patients;
  final List<PendingInvite> pending;

  const CareOverview({this.patients = const [], this.pending = const []});
}

/// 아직 수락하지 않은 초대.
///
/// 초대를 보냈다고 현황이 열리지는 않는다. 어르신이 수락해야 열린다 —
/// 동의 없이 남의 복약을 들여다보는 길을 만들지 않는다.
class PendingInvite {
  /// 서버에 저장된 요청 id. 아직 저장 전이면 null.
  final String? id;
  final String name;
  final String relation;
  final String phone;
  const PendingInvite({
    this.id,
    required this.name,
    required this.relation,
    required this.phone,
  });
}

class ActivityItem {
  final String text;

  /// 절대시간 문자열. **상대시간("15분 전")은 쓰지 않는다.**
  final String time;
  const ActivityItem(this.text, this.time);
}

class AlertItem {
  /// 'miss'·'alert' 위험 · 'refill' 약 떨어짐 · 'shared' 어르신이 보냄 ·
  /// 'done' 복약 완료 · 'prescription' 새 처방전 · 'past' 지난 것.
  final String type;
  final String title;
  final String desc;
  final String time;
  final bool tappable; // 심박 이상 → 상세로
  const AlertItem({
    required this.type,
    required this.title,
    required this.desc,
    required this.time,
    this.tappable = false,
  });
}
