import 'package:alkong_yakong/features/auth/presentation/screens/signup_screen.dart';
import 'package:alkong_yakong/features/guardian/presentation/screens/care_patient_screen.dart';
import 'package:alkong_yakong/features/profile/domain/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('회원가입 병력 배열과 기존 불리언을 함께 만든다', () {
    final payload = buildIllnessHistoryPayload(
      pastIllnesses: const {'암', '뇌졸중'},
      familyIllnesses: const {'심장병'},
    );

    expect(payload['past_illnesses'], ['암', '뇌졸중']);
    expect(payload['family_illnesses'], ['심장병']);
    expect(payload['past_history'], isTrue);
    expect(payload['family_history'], isTrue);
  });

  test('없어요 선택은 빈 배열과 false로 보낸다', () {
    final payload = buildIllnessHistoryPayload(
      pastIllnesses: const {'없어요'},
      familyIllnesses: const {'없어요'},
    );

    expect(payload['past_illnesses'], isEmpty);
    expect(payload['family_illnesses'], isEmpty);
    expect(payload['past_history'], isFalse);
    expect(payload['family_history'], isFalse);
  });

  test('이전 Backend 응답은 새 병력 배열을 빈 목록으로 읽는다', () {
    final profile = UserProfile.fromJson(const {
      'id': 'old-user',
      'name': '김복자',
      'past_history': true,
      'family_history': false,
    });

    expect(profile.pastIllnesses, isEmpty);
    expect(profile.familyIllnesses, isEmpty);
    expect(profile.pastHistory, isTrue);
    expect(profile.familyHistory, isFalse);
  });

  test('새 병력 배열은 사용자 모델의 저장 payload에도 유지된다', () {
    const profile = UserProfile(
      id: 'new-user',
      name: '김복자',
      pastHistory: true,
      familyHistory: true,
      pastIllnesses: ['암', '뇌졸중'],
      familyIllnesses: ['심장병'],
    );

    expect(profile.toJson()['past_illnesses'], ['암', '뇌졸중']);
    expect(profile.toJson()['family_illnesses'], ['심장병']);
  });

  test('보호자 화면은 병명 목록을 우선하고 기존 불리언으로 fallback한다', () {
    expect(illnessHistoryLabel(const ['암', '뇌졸중'], true), '암, 뇌졸중');
    expect(illnessHistoryLabel(const [], true), '있으세요');
    expect(illnessHistoryLabel(const [], false), '없어요');
    expect(illnessHistoryLabel(const [], null), isNull);
  });
}
