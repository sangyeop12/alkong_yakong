import 'dart:convert';

import 'package:alkong_yakong/core/network/api_client.dart';
import 'package:alkong_yakong/core/session/mvp_session.dart';
import 'package:alkong_yakong/features/guardian/data/guardian_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 보호자 화면은 서버가 준 어르신만 보여준다. 예시 어르신을 섞지 않는다.
void main() {
  GuardianRepository repositoryReturning(Object body, {int status = 200}) {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );
    return GuardianRepository(apiClient: ApiClient(client: client));
  }

  setUp(() => MvpSession.userId = 'g1');

  test('연결된 어르신과 수락 대기를 나눠 읽는다', () async {
    final overview = await repositoryReturning({
      'patients': [
        {
          'link_id': 'l1',
          'patient_id': 'p1',
          'name': '김복자',
          'relation': '어머니',
          'phone': '010-1111-2222',
          'age': 72,
          'taken_count': 1,
          'total_count': 3,
          'next_dose_label': '점심 약',
          'slots': [
            {'label': '아침', 'taken': true},
            {'label': '점심', 'taken': false},
          ],
          'heart_rate': 78,
          'heart_rate_normal': true,
          'week_rate': null,
          'activities': [
            {'text': '아침 약 드셨어요', 'time': '08:10'},
          ],
        },
      ],
      'pending': [
        {
          'id': 'l2',
          'patient_name': '김철수',
          'patient_phone': '010-5555-6666',
          'patient_relation': null,
        },
      ],
    }).fetchCareOverview();

    final patient = overview.patients.single;
    expect(patient.title, '어머니 · 김복자');
    expect(patient.needsAttention, isTrue);
    expect(patient.slots.first.taken, isTrue);
    expect(patient.weekRate, isNull);
    expect(patient.activities.single.time, '08:10');
    expect(overview.pending.single.id, 'l2');
    expect(overview.pending.single.relation, '');
  });

  test('없는 번호로 요청하면 보낸 것으로 치지 않는다', () async {
    final result = await repositoryReturning({
      'detail': '그 번호로 가입한 어르신이 없어요.',
    }, status: 404).requestLink(relation: '어머니', phone: '010-9999-9999');

    expect(result.isSent, isFalse);
    expect(result.error, '그 번호로 가입한 어르신이 없어요.');
  });

  test('목록을 못 읽으면 빈 목록으로 속이지 않고 실패를 올린다', () async {
    expect(
      repositoryReturning({'detail': '서버 오류'}, status: 500).fetchCareOverview(),
      throwsA(isA<ApiException>()),
    );
  });
}
