import 'package:alkong_yakong/core/network/api_client.dart';
import 'package:alkong_yakong/core/session/auth_session.dart';
import 'package:alkong_yakong/core/session/mvp_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    MvpSession.userId = 'mvp-user';
    await AuthSession.load();
  });

  test('회원가입 user id를 메모리와 SharedPreferences에 즉시 저장한다', () async {
    await AuthSession.persistUserId('backend-user-id');

    final preferences = await SharedPreferences.getInstance();
    expect(MvpSession.userId, 'backend-user-id');
    expect(preferences.getString('userId'), 'backend-user-id');
  });

  test('mvp-user는 backend 사용자 확인 없이 거부한다', () async {
    var requested = false;
    final apiClient = ApiClient(
      client: MockClient((request) async {
        requested = true;
        return http.Response('{}', 200);
      }),
    );

    expect(await AuthSession.hasValidBackendUser(apiClient), isFalse);
    expect(requested, isFalse);
  });

  test('저장된 id가 backend 응답 id와 일치할 때만 유효하다', () async {
    MvpSession.userId = 'backend-user-id';
    final validClient = ApiClient(
      client: MockClient(
        (request) async => http.Response(
          '{"id":"backend-user-id"}',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    final missingClient = ApiClient(
      client: MockClient(
        (request) async => http.Response('{"detail":"not found"}', 404),
      ),
    );

    expect(await AuthSession.hasValidBackendUser(validClient), isTrue);
    expect(await AuthSession.hasValidBackendUser(missingClient), isFalse);
  });
}
