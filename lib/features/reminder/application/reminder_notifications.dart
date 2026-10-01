import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'alarm_preferences.dart';

/// 매일 같은 시각에 울릴 알림 하나.
///
/// 플러그인 타입을 담지 않는다 — 무엇을 예약할지는 기기 없이 시험해야 하기 때문이다.
@immutable
class PlannedReminder {
  final int id;
  final int hour;
  final int minute;
  final String title;
  final String body;

  const PlannedReminder({
    required this.id,
    required this.hour,
    required this.minute,
    required this.title,
    required this.body,
  });

  @override
  String toString() =>
      'PlannedReminder($id, $hour:${minute.toString().padLeft(2, '0')})';
}

/// 알림 설정 → 예약할 알림 목록. 순수 계산만 한다.
abstract final class ReminderPlan {
  /// id를 고정해 두어야 예약을 바꿀 때 예전 것을 정확히 지울 수 있다.
  /// 정시 알림 id는 7001부터, 10분 뒤 다시 알림은 7101부터 차례로 쓴다.
  static const baseId = 7001;
  static const followUpBaseId = 7101;

  /// 다시 맞출 때마다 전부 지운다. 꺼 둔 알림이 남아서 울리면 안 된다.
  /// 시각을 지웠을 때 그 자리 알림도 같이 지워져야 하므로 자리 수만큼 돈다.
  static List<int> get allIds => [
    for (int i = 0; i < AlarmPreferences.maxHours; i++) baseId + i,
    for (int i = 0; i < AlarmPreferences.maxHours; i++) followUpBaseId + i,
  ];

  static const followUpMinutes = 10;
  static const title = '약 드실 시간이에요';
  static const followUpTitle = '약 드셨나요?';

  static List<PlannedReminder> forPrefs(AlarmPreferences prefs) {
    if (!prefs.autoAlarm) return const [];
    final hours = prefs.hours;
    return [
      for (int i = 0; i < hours.length; i++) _onTime(baseId + i, hours[i]),
      if (prefs.repeatOnce)
        for (int i = 0; i < hours.length; i++)
          _followUp(followUpBaseId + i, hours[i]),
    ];
  }

  static PlannedReminder _onTime(int id, int hour) => PlannedReminder(
    id: id,
    hour: hour,
    minute: 0,
    title: title,
    body: '${AlarmPreferences.clock(hour)} 약을 물과 함께 드세요.',
  );

  static PlannedReminder _followUp(int id, int hour) {
    // 저녁 11시대라도 하루 안으로 감기게 분 단위로 더한다.
    final total = (hour * 60 + followUpMinutes) % (24 * 60);
    return PlannedReminder(
      id: id,
      hour: total ~/ 60,
      minute: total % 60,
      title: followUpTitle,
      body: '${AlarmPreferences.clock(hour)} 약, 아직 안 드셨다면 지금 드세요.',
    );
  }

  /// [now] 뒤에 처음 오는 그 시각. 딱 그 시각이면 이미 지난 것으로 보고 내일로 둔다.
  ///
  /// 하루를 Duration으로 더하지 않고 날짜로 넘긴다 — 서머타임이 있는 곳에서도
  /// 시계 시각이 밀리지 않게.
  static tz.TZDateTime nextInstance(PlannedReminder r, tz.TZDateTime now) {
    final today = tz.TZDateTime(
      now.location,
      now.year,
      now.month,
      now.day,
      r.hour,
      r.minute,
    );
    if (today.isAfter(now)) return today;
    return tz.TZDateTime(
      now.location,
      now.year,
      now.month,
      now.day + 1,
      r.hour,
      r.minute,
    );
  }
}

/// 실제 전화기 알림을 예약한다.
///
/// 플러그인이 없는 곳(위젯 테스트, 데스크톱)에서는 [initialize]가 조용히 실패하고
/// 나머지 호출은 아무것도 하지 않는다. 알림 때문에 앱이나 테스트가 멈추면 안 된다.
class ReminderNotifications {
  ReminderNotifications();

  /// main()에서 초기화한 것과 provider가 같은 객체를 쓰게 한다.
  static final instance = ReminderNotifications();

  /// 잠금화면 단추 이름. 알림에서 바로 누른다.
  static const takeActionId = 'take';
  static const snoozeActionId = 'snooze';

  /// 잠금화면에서 누른 단추. 오늘 화면이 이것을 보고 대신 처리한다.
  ///
  /// 알림을 받은 곳(백그라운드)에서는 서버에 기록할 수 없다. 앱이 올라온 뒤
  /// 같은 자리에서 처리해야 기록이 어긋나지 않는다.
  static final ValueNotifier<String?> pendingAction = ValueNotifier<String?>(
    null,
  );

  static const _channelId = 'medication_reminder';
  static const _channelName = '복약 알림';
  static const _channelDescription = '약 드실 시간을 소리로 알려드려요';

  FlutterLocalNotificationsPlugin? _plugin;
  bool _ready = false;
  Future<bool>? _notificationAsk;
  Future<void> _queue = Future.value();

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      ?.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  IOSFlutterLocalNotificationsPlugin? get _ios => _plugin
      ?.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin
      >();

  Future<void> initialize() async {
    if (_ready) return;
    try {
      tz_data.initializeTimeZones();
      tz.setLocalLocation(await _localLocation());

      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.initialize(
        onDidReceiveNotificationResponse: _onResponse,
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          // 앱을 켜자마자 권한 창을 띄우지 않는다. 알림이 필요할 때 따로 묻는다.
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestSoundPermission: false,
            requestBadgePermission: false,
          ),
        ),
      );
      _plugin = plugin;
      await _android?.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDescription,
          importance: Importance.high,
          playSound: true,
        ),
      );
      // 알림 단추로 앱이 켜졌으면 그 단추도 받아 둔다.
      final launch = await plugin.getNotificationAppLaunchDetails();
      final launchAction = launch?.notificationResponse?.actionId;
      if (launch?.didNotificationLaunchApp == true &&
          launchAction != null &&
          launchAction.isNotEmpty) {
        pendingAction.value = launchAction;
      }
      _ready = true;
    } catch (e) {
      debugPrint('복약 알림 초기화 실패: $e');
    }
  }

  static void _onResponse(NotificationResponse response) {
    final action = response.actionId;
    if (action == null || action.isEmpty) return;
    pendingAction.value = action;
  }

  static Future<tz.Location> _localLocation() async {
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      return tz.getLocation(info.identifier);
    } catch (_) {
      // 기기 시간대를 못 읽어도 알림은 한국 시각으로라도 울려야 한다.
      return tz.getLocation('Asia/Seoul');
    }
  }

  /// 알림을 띄워도 되는지 묻는다. 분명히 거절됐을 때만 false.
  ///
  /// [exactAlarm]이면 안드로이드 "알람 및 리마인더" 허용도 받으러 간다.
  /// 이 설정 화면은 낯설 수 있어서 사용자가 직접 알림을 켤 때만 연다.
  Future<bool> requestPermissions({bool exactAlarm = false}) async {
    if (!_ready) return true;
    // 동시에 두 번 물으면 안드로이드가 오류를 낸다. 한 번 물은 답을 같이 쓴다.
    final allowed = await (_notificationAsk ??= _askNotifications());
    if (allowed && exactAlarm) {
      try {
        final android = _android;
        if (android != null &&
            await android.canScheduleExactNotifications() == false) {
          await android.requestExactAlarmsPermission();
        }
      } catch (e) {
        debugPrint('정확한 알람 권한 요청 실패: $e');
      }
    }
    return allowed;
  }

  Future<bool> _askNotifications() async {
    try {
      final android = _android;
      if (android != null) {
        return await android.requestNotificationsPermission() ?? true;
      }
      final ios = _ios;
      if (ios != null) {
        return await ios.requestPermissions(alert: true, sound: true) ?? true;
      }
    } catch (e) {
      debugPrint('알림 권한 요청 실패: $e');
    }
    return true;
  }

  /// 예약을 [prefs]에 맞게 다시 만든다.
  ///
  /// 시간을 연달아 바꾸면 호출이 겹친다. 줄 세워 돌려야 지운 알림이
  /// 앞선 호출 때문에 되살아나지 않는다.
  Future<void> sync(AlarmPreferences prefs) =>
      _queue = _queue.then((_) => _sync(prefs));

  Future<void> _sync(AlarmPreferences prefs) async {
    if (!_ready) return;
    final plugin = _plugin!;
    try {
      for (final id in ReminderPlan.allIds) {
        await plugin.cancel(id: id);
      }
      final plan = ReminderPlan.forPrefs(prefs);
      if (plan.isEmpty) return;

      await requestPermissions();
      final mode = await _scheduleMode();
      final now = tz.TZDateTime.now(tz.local);
      for (final reminder in plan) {
        await _schedule(plugin, reminder, now, mode);
      }
    } catch (e) {
      debugPrint('복약 알림 예약 실패: $e');
    }
  }

  /// 정확한 알람이 허용되지 않았으면 몇 분 늦더라도 울리는 쪽을 고른다.
  Future<AndroidScheduleMode> _scheduleMode() async {
    try {
      final exact = await _android?.canScheduleExactNotifications();
      if (exact == false) return AndroidScheduleMode.inexactAllowWhileIdle;
    } catch (_) {
      return AndroidScheduleMode.inexactAllowWhileIdle;
    }
    return AndroidScheduleMode.exactAllowWhileIdle;
  }

  Future<void> _schedule(
    FlutterLocalNotificationsPlugin plugin,
    PlannedReminder reminder,
    tz.TZDateTime now,
    AndroidScheduleMode mode,
  ) async {
    Future<void> schedule(AndroidScheduleMode m) => plugin.zonedSchedule(
      id: reminder.id,
      title: reminder.title,
      body: reminder.body,
      scheduledDate: ReminderPlan.nextInstance(reminder, now),
      notificationDetails: _details(reminder),
      androidScheduleMode: m,
      matchDateTimeComponents: DateTimeComponents.time,
    );

    try {
      await schedule(mode);
    } on PlatformException catch (e) {
      // 확인 뒤에 사용자가 권한을 거둬 갔을 수 있다. 느슨한 예약으로 한 번 더.
      if (e.code != 'exact_alarms_not_permitted') rethrow;
      await schedule(AndroidScheduleMode.inexactAllowWhileIdle);
    }
  }

  static NotificationDetails _details(PlannedReminder reminder) =>
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          // 글자를 크게 쓰는 분도 문장이 잘리지 않게 펼쳐 보인다.
          styleInformation: BigTextStyleInformation(reminder.body),
          // 앱을 열지 않아도 여기서 끝낼 수 있게 두 단추를 둔다.
          actions: const [
            AndroidNotificationAction(
              takeActionId,
              '먹었어요',
              showsUserInterface: true,
            ),
            AndroidNotificationAction(
              snoozeActionId,
              '30분 뒤에 다시',
              showsUserInterface: true,
            ),
          ],
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentList: true,
          presentSound: true,
        ),
      );
}

/// 테스트에서는 가짜로 바꿔 끼운다.
final reminderNotificationsProvider = Provider<ReminderNotifications>(
  (ref) => ReminderNotifications.instance,
);
