import 'dart:convert';

import 'package:alkong_yakong/core/network/api_client.dart';
import 'package:alkong_yakong/core/session/mvp_session.dart';
import 'package:alkong_yakong/features/guardian/data/guardian_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 초대는 보냈는지 못 보냈는지가 분명해야 한다.
/// 실패했는데 목록에 올려 두면 어르신은 초대를 받은 적이 없는데
/// 보호자만 기다리게 된다.
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

  setUp(() => MvpSession.userId = 'u1');

  test('서버가 받아 주면 보낸 것으로 본다', () async {
    final result = await repositoryReturning({
      'id': 'g1',
    }).invite(name: '김지안', relation: '딸', phone: '010-1111-2222');

    expect(result.isSent, isTrue);
    expect(result.invite!.name, '김지안');
    expect(result.invite!.relation, '딸');
    expect(result.error, isNull);
  });

  test('서버가 거절하면 보낸 것으로 치지 않는다', () async {
    final result = await repositoryReturning({
      'detail': '사용자가 없습니다.',
    }, status: 404).invite(name: '김지안', relation: '딸', phone: '010-1111-2222');

    expect(result.isSent, isFalse);
    expect(result.invite, isNull);
    expect(result.error, isNotNull);
  });

  test('로그인 전에는 부르지 않는다', () async {
    MvpSession.userId = '';
    final result = await repositoryReturning({
      'id': 'g1',
    }).invite(name: '김지안', relation: '딸', phone: '010-1111-2222');

    expect(result.isSent, isFalse);
    expect(result.error, '로그인이 필요해요');
  });
}
