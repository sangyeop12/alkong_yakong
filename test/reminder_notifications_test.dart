import 'package:alkong_yakong/features/reminder/application/alarm_preferences.dart';
import 'package:alkong_yakong/features/reminder/application/reminder_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

class _FakeNotifications extends ReminderNotifications {
  final synced = <AlarmPreferences>[];

  @override
  Future<void> sync(AlarmPreferences prefs) async => synced.add(prefs);
}

void main() {
  group('ReminderPlan.forPrefs', () {
    test('자동 알림을 끄면 아무것도 예약하지 않는다', () {
      expect(
        ReminderPlan.forPrefs(const AlarmPreferences(autoAlarm: false)),
        isEmpty,
      );
    });

    test('켜면 고른 시각마다 정시에 예약한다', () {
      final plan = ReminderPlan.forPrefs(
        const AlarmPreferences(repeatOnce: false, hours: [8, 13, 18]),
      );

      expect(plan.map((r) => r.id), [
        ReminderPlan.baseId,
        ReminderPlan.baseId + 1,
        ReminderPlan.baseId + 2,
      ]);
      expect([plan[0].hour, plan[0].minute], [8, 0]);
      expect([plan[1].hour, plan[1].minute], [13, 0]);
      expect([plan[2].hour, plan[2].minute], [18, 0]);
      expect(plan[0].title, '약 드실 시간이에요');
      expect(plan[0].body, '오전 8시 약을 물과 함께 드세요.');
      expect(plan[2].body, '오후 6시 약을 물과 함께 드세요.');
    });

    test('시각은 겹치지 않고 순서대로 선다', () {
      const prefs = AlarmPreferences(hours: [18, 8, 8]);
      expect(prefs.hours, [8, 18]);
      expect(const AlarmPreferences(hours: []).hours, [8]);
    });

    test('마지막 한 개는 지워지지 않는다', () {
      const prefs = AlarmPreferences(hours: [9]);
      expect(prefs.withoutHour(9).hours, [9]);
      expect(const AlarmPreferences(hours: [9, 21]).withoutHour(9).hours, [21]);
    });

    test('10분 뒤 한 번 더를 켜면 두 배, 다시 알림은 10분 뒤', () {
      final plan = ReminderPlan.forPrefs(
        const AlarmPreferences(hours: [7, 20]),
      );
      final byId = {for (final r in plan) r.id: r};

      expect(plan, hasLength(4));
      expect(
        byId.keys.toSet().difference(ReminderPlan.allIds.toSet()),
        isEmpty,
      );
      expect(
        [byId[ReminderPlan.baseId]!.hour, byId[ReminderPlan.baseId]!.minute],
        [7, 0],
      );
      expect(
        [
          byId[ReminderPlan.baseId + 1]!.hour,
          byId[ReminderPlan.baseId + 1]!.minute,
        ],
        [20, 0],
      );

      final morningAgain = byId[ReminderPlan.followUpBaseId]!;
      final eveningAgain = byId[ReminderPlan.followUpBaseId + 1]!;
      expect([morningAgain.hour, morningAgain.minute], [7, 10]);
      expect([eveningAgain.hour, eveningAgain.minute], [20, 10]);
      expect(morningAgain.body, contains('아직 안 드셨다면 지금 드세요.'));
      expect(eveningAgain.body, startsWith('오후 8시'));
    });
  });

  group('ReminderPlan.nextInstance', () {
    late tz.Location seoul;
    const morning = PlannedReminder(
      id: ReminderPlan.baseId,
      hour: 8,
      minute: 0,
      title: '',
      body: '',
    );

    setUpAll(() {
      tz_data.initializeTimeZones();
      seoul = tz.getLocation('Asia/Seoul');
    });

    test('아직 안 된 시각이면 오늘', () {
      final now = tz.TZDateTime(seoul, 2026, 9, 14, 7, 30);
      expect(
        ReminderPlan.nextInstance(morning, now),
        tz.TZDateTime(seoul, 2026, 9, 14, 8),
      );
    });

    test('딱 그 시각이거나 지났으면 내일, 달이 바뀌어도', () {
      expect(
        ReminderPlan.nextInstance(
          morning,
          tz.TZDateTime(seoul, 2026, 9, 14, 8),
        ),
        tz.TZDateTime(seoul, 2026, 9, 15, 8),
      );
      expect(
        ReminderPlan.nextInstance(
          morning,
          tz.TZDateTime(seoul, 2026, 9, 30, 21),
        ),
        tz.TZDateTime(seoul, 2026, 10, 1, 8),
      );
    });
  });

  test('플러그인이 없는 곳에서도 초기화·예약·권한 요청이 터지지 않는다', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final notifications = ReminderNotifications();

    await notifications.initialize();
    await notifications.sync(const AlarmPreferences());
    expect(await notifications.requestPermissions(exactAlarm: true), isTrue);
  });

  test('저장된 설정을 읽은 뒤와 바꿀 때마다 알림을 다시 맞춘다', () async {
    // 옛 버전의 아침·저녁 값도 새 목록으로 옮겨 읽는다.
    SharedPreferences.setMockInitialValues({'alarm.morning': 9});
    final fake = _FakeNotifications();
    final container = ProviderContainer(
      overrides: [reminderNotificationsProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    container.read(alarmPreferencesProvider);
    await pumpEventQueue();
    expect(fake.synced.single.hours, [9]);

    await container
        .read(alarmPreferencesProvider.notifier)
        .update(const AlarmPreferences(autoAlarm: false));
    expect(fake.synced, hasLength(2));
    expect(fake.synced.last.autoAlarm, isFalse);
  });
}
