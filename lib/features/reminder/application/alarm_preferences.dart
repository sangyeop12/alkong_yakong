import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reminder_notifications.dart';

/// 복약 알림 설정. 앱을 껐다 켜도 고른 값이 남는다.
@immutable
class AlarmPreferences {
  final bool autoAlarm;
  final bool repeatOnce;
  final bool tellGuardian;

  /// 들어온 그대로의 시각 목록. 읽을 때는 [hours]로 정리해서 쓴다.
  final List<int> _rawHours;

  const AlarmPreferences({
    this.autoAlarm = true,
    this.repeatOnce = true,
    this.tellGuardian = true,
    List<int> hours = const [8, 18],
  }) : _rawHours = hours;

  /// 알림 시각(24시간제). 오름차순이고 겹치지 않는다. 적어도 하나는 남는다.
  List<int> get hours => normalize(_rawHours);

  /// 한 사람이 챙길 수 있는 알림은 이 정도가 끝이다.
  static const int maxHours = 6;

  AlarmPreferences copyWith({
    bool? autoAlarm,
    bool? repeatOnce,
    bool? tellGuardian,
    List<int>? hours,
  }) => AlarmPreferences(
    autoAlarm: autoAlarm ?? this.autoAlarm,
    repeatOnce: repeatOnce ?? this.repeatOnce,
    tellGuardian: tellGuardian ?? this.tellGuardian,
    hours: normalize(hours ?? this.hours),
  );

  /// 시각을 더한다. 이미 있는 시각이면 그대로 둔다.
  AlarmPreferences withHour(int hour) =>
      hours.contains(hour) || hours.length >= maxHours
      ? this
      : copyWith(hours: [...hours, hour]);

  /// 시각을 지운다. 마지막 하나는 지우지 않는다 — 알림이 통째로 사라진다.
  AlarmPreferences withoutHour(int hour) => hours.length <= 1
      ? this
      : copyWith(
          hours: [
            for (final h in hours)
              if (h != hour) h,
          ],
        );

  /// [was]를 [now]로 바꾼다.
  AlarmPreferences replaceHour(int was, int now) => copyWith(
    hours: [
      for (final h in hours)
        if (h == was) now else h,
    ],
  );

  /// 겹치는 시각을 덜어내고 순서대로 세운다. 비면 기본값으로 돌린다.
  static List<int> normalize(List<int> raw) {
    final kept = <int>{
      for (final hour in raw)
        if (hour >= 0 && hour <= 23) hour,
    }.toList()..sort();
    if (kept.isEmpty) return const [8];
    return List<int>.unmodifiable(kept.take(maxHours));
  }

  /// "오전 8시" · "낮 12시" · "오후 6시".
  static String clock(int hour) {
    if (hour == 0) return '밤 12시';
    if (hour == 12) return '낮 12시';
    return hour < 12 ? '오전 $hour시' : '오후 ${hour - 12}시';
  }

  /// 내 정보 목록에 쓰는 한 줄.
  String get summary => autoAlarm
      ? '${hours.map(clock).join(' · ')} · 소리로 알려드려요'
      : '소리 알림이 꺼져 있어요';
}

class AlarmPreferencesController extends Notifier<AlarmPreferences> {
  static const _prefix = 'alarm.';

  @override
  AlarmPreferences build() {
    Future.microtask(_load);
    return const AlarmPreferences();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const defaults = AlarmPreferences();
      state = AlarmPreferences(
        autoAlarm: prefs.getBool('${_prefix}auto') ?? defaults.autoAlarm,
        repeatOnce: prefs.getBool('${_prefix}repeat') ?? defaults.repeatOnce,
        tellGuardian:
            prefs.getBool('${_prefix}guardian') ?? defaults.tellGuardian,
        hours: _readHours(prefs) ?? defaults.hours,
      );
    } catch (_) {
      // 저장소를 못 열면 기본값으로 둔다.
    }
    // 저장소를 못 열었어도 기본값대로는 울려야 한다.
    await ref.read(reminderNotificationsProvider).sync(state);
  }

  /// 새 목록을 읽는다. 없으면 옛 아침·저녁 값을 옮겨 온다.
  static List<int>? _readHours(SharedPreferences prefs) {
    final stored = prefs.getStringList('${_prefix}hours');
    if (stored != null && stored.isNotEmpty) {
      return AlarmPreferences.normalize([
        for (final text in stored) int.tryParse(text) ?? -1,
      ]);
    }
    final morning = prefs.getInt('${_prefix}morning');
    final evening = prefs.getInt('${_prefix}evening');
    if (morning == null && evening == null) return null;
    return AlarmPreferences.normalize([?morning, ?evening]);
  }

  Future<void> update(AlarmPreferences next) async {
    state = next;
    // 저장이 실패해도 전화기 알림은 지금 고른 값을 따라가야 한다.
    unawaited(ref.read(reminderNotificationsProvider).sync(next));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('${_prefix}auto', next.autoAlarm);
      await prefs.setBool('${_prefix}repeat', next.repeatOnce);
      await prefs.setBool('${_prefix}guardian', next.tellGuardian);
      await prefs.setStringList('${_prefix}hours', [
        for (final hour in next.hours) '$hour',
      ]);
    } catch (_) {
      // 화면에는 이미 반영됐다. 다음 실행 때 기본값으로 돌아갈 뿐이다.
    }
  }
}

final alarmPreferencesProvider =
    NotifierProvider<AlarmPreferencesController, AlarmPreferences>(
      AlarmPreferencesController.new,
    );
