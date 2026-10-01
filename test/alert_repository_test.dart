import 'dart:convert';

import 'package:alkong_yakong/core/network/api_client.dart';
import 'package:alkong_yakong/features/guardian/data/alert_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 알림은 종류를 몰라도 버리지 않는다.
/// 안 보여주면 보호자는 그런 일이 없었다고 믿는다.
void main() {
  AlertRepository repositoryReturning(Object body, {int status = 200}) {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );
    return AlertRepository(apiClient: ApiClient(client: client));
  }

  test('서버 종류를 화면이 아는 갈래로 옮긴다', () async {
    final alerts = await repositoryReturning([
      {
        'notification_type': 'ABNORMAL_HEART_RATE',
        'title': '심장 박동이 빨라요',
        'message': '분당 125회까지 올랐어요',
        'created_at': '2026-09-10T14:16:00',
      },
      {
        'notification_type': 'MEDICATION_MISSED',
        'title': '약을 안 드셨어요',
        'message': '저녁 약을 드시지 않았어요',
        'created_at': '2026-09-09T20:00:00',
      },
    ]).fetch('u1');

    expect(alerts, isNotNull);
    expect(alerts![0].type, 'alert');
    expect(alerts[1].type, 'miss');
  });

  test('모르는 종류도 버리지 않는다', () async {
    final alerts = await repositoryReturning([
      {
        'notification_type': 'SOMETHING_NEW',
        'title': '새 소식',
        'message': '무언가 있었어요',
        'created_at': '2026-09-10T09:00:00',
      },
    ]).fetch('u1');

    expect(alerts!.length, 1);
    expect(alerts.first.type, 'past');
    expect(alerts.first.desc, '무언가 있었어요');
  });

  test('상대시간을 쓰지 않는다', () async {
    final alerts = await repositoryReturning([
      {
        'notification_type': 'MEDICATION_TAKEN',
        'title': '약 다 드셨어요',
        'message': '점심 약',
        'created_at': '2026-01-02T08:05:00',
      },
    ]).fetch('u1');

    // "몇 분 전"이 아니라 언제인지 그대로 적는다.
    expect(alerts!.first.time, '1월 2일 08:05');
  });

  test('못 읽으면 null — 데모로 갈아끼우지 않는다', () async {
    expect(
      await repositoryReturning({'detail': 'x'}, status: 500).fetch('u1'),
      isNull,
    );
    expect(await repositoryReturning(<dynamic>[]).fetch(''), isNull);
  });
}
