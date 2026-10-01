import 'dart:convert';

import 'package:alkong_yakong/core/network/api_client.dart';
import 'package:alkong_yakong/core/session/mvp_session.dart';
import 'package:alkong_yakong/features/biosignal/data/heart_repository.dart';
import 'package:alkong_yakong/features/biosignal/domain/heart_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 서버 응답을 화면이 쓰는 모양으로 옮기는 자리.
/// 여기서 조용히 틀리면 가짜 숫자가 진짜 기록으로 보인다.
void main() {
  HeartRepository repositoryReturning(Object body, {int status = 200}) {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode(
          body is Map
              ? {'readings': [], 'period_date': '2026-09-18', ...body}
              : body,
        ),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );
    return HeartRepository(apiClient: ApiClient(client: client));
  }

  setUp(() => MvpSession.userId = 'u1');

  test('전·후 쌍과 주·월을 그대로 옮긴다', () async {
    final data = await repositoryReturning({
      'today': {'before': 78, 'after': 72},
      'today_slot_label': '저녁 약',
      'before_at': '17:45',
      'after_at': '18:20',
      'week': [
        {'weekday': '월', 'before': 80, 'after': 74},
        {'weekday': '화', 'before': null, 'after': null},
      ],
      'month': [
        {'day': 1, 'before': 80, 'after': 74},
        {'day': 2, 'before': null, 'after': null},
      ],
      'streak_days': 9,
      'best_streak_days': 14,
      'anomaly': {'day': 12, 'label': '9월 12일', 'before': 96, 'after': 84},
    }).fetch();

    expect(data, isNotNull);
    expect(data!.today.before, 78);
    expect(data.today.after, 72);
    expect(data.today.drop, 6);
    expect(data.week.length, 2);
    expect(data.week.first.weekday, '월');
    expect(data.month[1].isMissing, isTrue);
    expect(data.streakDays, 9);
    expect(data.anomaly!.day, 12);
    // 어르신 화면은 24시간 표기를 쓰지 않는다.
    expect(data.beforeAt, '오후 5시 45분');
    expect(data.afterAt, '오후 6시 20분');
    // 서버 label("9월 12일")을 때 이름으로 쓰면 날짜가 두 번 붙는다.
    expect(data.anomaly!.slotLabel, '');
    // 센서 상태는 기록에서 지어내지 않는다.
    expect(data.sensorBattery, isNull);
    expect(data.sensorLastReadAt, '');
  });

  test('오늘 때 이름을 서버가 안 주면 "저녁 약"을 지어내지 않는다', () async {
    final data = await repositoryReturning({
      'today': {'before': null, 'after': null},
      'week': <dynamic>[],
      'month': <dynamic>[],
    }).fetch();
    expect(data!.todaySlotLabel, '');
    expect(data.hasReadings, isFalse);
  });

  test('다른 사람 id를 넘기면 그 사람 기록을 부른다', () async {
    Uri? called;
    final client = MockClient((request) async {
      called = request.url;
      return http.Response(
        jsonEncode({'today': {}, 'week': [], 'month': []}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    await HeartRepository(
      apiClient: ApiClient(client: client),
    ).fetch(userId: 'patient-1');
    expect(called?.path, '/api/v1/users/patient-1/biosignal/heart-summary');
    expect(called?.queryParameters['include_readings'], 'true');
    expect(
      called?.queryParameters['utc_offset_minutes'],
      '${DateTime.now().timeZoneOffset.inMinutes}',
    );
  });

  test('못 잰 쪽은 비운 채로 둔다 — 숫자를 지어내지 않는다', () async {
    final data = await repositoryReturning({
      'today': {'before': null, 'after': 72},
      'week': <dynamic>[],
      'month': <dynamic>[],
      'anomaly': null,
    }).fetch();

    expect(data!.today.before, isNull);
    expect(data.today.after, 72);
    expect(data.today.isComplete, isFalse);
    expect(data.today.drop, isNull);
    expect(data.beforeAt, '');
    expect(data.anomaly, isNull);
  });

  test('이상한 날은 세 값이 다 있어야 인정한다', () async {
    final data = await repositoryReturning({
      'today': {'before': 78, 'after': 72},
      'week': <dynamic>[],
      'month': <dynamic>[],
      // after 가 빠졌다. 이걸로 "이상했던 날"이라고 말할 수 없다.
      'anomaly': {'day': 12, 'before': 96},
    }).fetch();

    expect(data!.anomaly, isNull);
  });

  test('서버가 실패하면 null — 데모로 조용히 갈아끼우지 않는다', () async {
    final data = await repositoryReturning({
      'detail': '없음',
    }, status: 500).fetch();
    expect(data, isNull);
  });

  test('로그인 전이면 부르지 않는다', () async {
    MvpSession.userId = '';
    final data = await repositoryReturning({'today': {}}).fetch();
    expect(data, isNull);
  });

  test('주 시작과 월 시작은 같은 현지 날짜 경계를 사용한다', () async {
    final data = await repositoryReturning({
      'period_date': '2026-06-01',
      'readings': [
        {
          'id': 1,
          'bpm': 98,
          'measured_at': DateTime(2026, 6, 1).toUtc().toIso8601String(),
        },
        {
          'id': 2,
          'bpm': 71,
          'measured_at': DateTime(
            2026,
            5,
            31,
            23,
            59,
          ).toUtc().toIso8601String(),
        },
      ],
    }).fetch();
    expect(data!.readingsFor(monthly: false).map((r) => r.id), [1]);
    expect(data.readingsFor(monthly: true).map((r) => r.id), [1]);
  });

  test('단독 기록은 전후 쌍을 만들지 않고 유지한다', () async {
    final data = await repositoryReturning({
      'today': {},
      'week': [],
      'month': [],
      'readings': [
        {
          'id': 7,
          'bpm': 98,
          'measured_at': '2026-09-18T05:42:00Z',
          'measurement_context': 'before_medication',
        },
      ],
    }).fetch();
    expect(data!.readings.single.bpm, 98);
    expect(
      data.readings.single.measurementContext,
      HeartMeasurementContext.beforeMedication,
    );
    expect(data.today.isComplete, isFalse);
    expect(data.today.before, isNull);
    expect(data.today.after, isNull);
    expect(
      data.readings.single.measuredAt,
      DateTime.parse('2026-09-18T05:42:00Z').toLocal(),
    );
    expect(data.hasReadings, isTrue);
  });

  test('목적 필드가 없는 이전 응답과 알 수 없는 값은 일반 측정이다', () async {
    final data = await repositoryReturning({
      'today': {},
      'week': [],
      'month': [],
      'readings': [
        {'id': 1, 'bpm': 70, 'measured_at': '2026-09-18T05:42:00Z'},
        {
          'id': 2,
          'bpm': 71,
          'measured_at': '2026-09-18T05:43:00Z',
          'measurement_context': 'unknown',
        },
      ],
    }).fetch();
    expect(
      data!.readings.map((reading) => reading.measurementContext),
      everyElement(HeartMeasurementContext.general),
    );
  });

  test('한국 현지 자정 경계에서 오늘 기록만 고른다', () async {
    final data = await repositoryReturning({
      'period_date': '2026-06-01',
      'today': {},
      'week': [],
      'month': [],
      'readings': [
        {
          'id': 1,
          'bpm': 80,
          'measured_at': '2026-05-31T14:59:00Z',
          'measurement_context': 'general',
        },
        {
          'id': 2,
          'bpm': 81,
          'measured_at': '2026-05-31T15:00:00Z',
          'measurement_context': 'general',
        },
      ],
    }).fetch();

    expect(DateTime.now().timeZoneOffset, const Duration(hours: 9));
    expect(data!.todayReadings.map((reading) => reading.id), [2]);
  });

  test('기록 목록 누락 또는 잘못된 시간은 빈 기록으로 간주하지 않는다', () async {
    expect(await repositoryReturning({'readings': null}).fetch(), isNull);
    expect(
      await repositoryReturning({
        'readings': [
          {'id': 1, 'bpm': 98, 'measured_at': 'bad'},
        ],
      }).fetch(),
      isNull,
    );
  });
}
