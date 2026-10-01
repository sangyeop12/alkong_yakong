import 'package:flutter/foundation.dart';

/// 서버에 저장된 내 정보.
///
/// 화면은 이 값을 읽기만 한다. 고칠 때는 [toJson]으로 보내고
/// 서버가 돌려준 값으로 다시 그린다 — 화면에 적힌 글자가 저장된 값과
/// 어긋나지 않게 하기 위해서다.
@immutable
class UserProfile {
  final String id;
  final String name;

  /// 'patient' · 'guardian' (서버 옛 값은 'PATIENT').
  final String role;
  final String? phone;
  final DateTime? birthDate;

  /// 'M' 또는 'F'.
  final String? gender;
  final bool isPregnant;
  final String? pregnancyStatus;
  final double? heightCm;
  final double? weightKg;
  final String? bloodType;
  final String? smoking;
  final String? drinking;
  final List<String> allergies;
  final List<String> diseases;
  final bool? pastHistory;
  final bool? familyHistory;
  final List<String> pastIllnesses;
  final List<String> familyIllnesses;

  const UserProfile({
    required this.id,
    required this.name,
    this.role = 'patient',
    this.phone,
    this.birthDate,
    this.gender,
    this.isPregnant = false,
    this.pregnancyStatus,
    this.heightCm,
    this.weightKg,
    this.bloodType,
    this.smoking,
    this.drinking,
    this.allergies = const [],
    this.diseases = const [],
    this.pastHistory,
    this.familyHistory,
    this.pastIllnesses = const [],
    this.familyIllnesses = const [],
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: _text(json['id']) ?? '',
      name: _text(json['name']) ?? '',
      role: _text(json['role']) ?? 'patient',
      phone: _text(json['phone']),
      birthDate: DateTime.tryParse(_text(json['birth_date']) ?? ''),
      gender: _text(json['gender']),
      isPregnant: _flag(json['is_pregnant']) ?? false,
      pregnancyStatus: _text(json['pregnancy_status']),
      heightCm: _number(json['height_cm']),
      weightKg: _number(json['weight_kg']),
      bloodType: _text(json['blood_type']),
      smoking: _text(json['smoking']),
      drinking: _text(json['drinking']),
      allergies: _texts(json['allergies']),
      diseases: _texts(json['diseases']),
      pastHistory: _flag(json['past_history']),
      familyHistory: _flag(json['family_history']),
      pastIllnesses: _texts(json['past_illnesses']),
      familyIllnesses: _texts(json['family_illnesses']),
    );
  }

  bool get isGuardian => role.trim().toLowerCase() == 'guardian';

  /// 만 나이. 생년월일이 없으면 null.
  int? ageAt(DateTime now) {
    final birth = birthDate;
    if (birth == null) return null;
    var age = now.year - birth.year;
    if (now.month < birth.month ||
        (now.month == birth.month && now.day < birth.day)) {
      age--;
    }
    return age;
  }

  /// "1958년생 · 68세". 생년월일이 없으면 빈 문자열.
  String ageLine(DateTime now) {
    final birth = birthDate;
    final age = ageAt(now);
    if (birth == null || age == null) return '';
    return '${birth.year}년생 · $age세';
  }

  /// PATCH /api/v1/users/{id} 에 그대로 보낸다.
  Map<String, dynamic> toJson() => {
    'name': name,
    'phone': phone,
    'birth_date': formatDate(birthDate),
    'gender': gender,
    'is_pregnant': isPregnant,
    'pregnancy_status': pregnancyStatus,
    'height_cm': heightCm,
    'weight_kg': weightKg,
    'blood_type': bloodType,
    'smoking': smoking,
    'drinking': drinking,
    'allergies': allergies,
    'diseases': diseases,
    'past_history': pastHistory,
    'family_history': familyHistory,
    'past_illnesses': pastIllnesses,
    'family_illnesses': familyIllnesses,
  };

  /// 서버가 받는 날짜 모양 "1958-04-10".
  static String? formatDate(DateTime? date) {
    if (date == null) return null;
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  static String? _text(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  static double? _number(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  static bool? _flag(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    return null;
  }

  static List<String> _texts(dynamic value) {
    if (value is! List) return const [];
    return [
      for (final item in value)
        if (item != null && item.toString().trim().isNotEmpty)
          item.toString().trim(),
    ];
  }
}
