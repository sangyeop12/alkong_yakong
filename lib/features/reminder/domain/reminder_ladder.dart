import '../../medication/domain/medication_models.dart';

/// 알림이 나가는 통로.
enum ReminderChannel {
  /// 잠금화면 알림 + 벨소리 수준 볼륨.
  lockScreenSound,

  /// 잠금화면 알림 + 소리 + 진동.
  lockScreenSoundVibration,

  /// 무음 모드에서도 울린다 (iOS critical alert).
  /// iOS는 별도 권한이 필요하다 — 온보딩에서 왜 필요한지 설명하고 요청한다.
  criticalAlert,

  /// 보호자 앱 푸시.
  guardianPush,
}

/// 재알림 사다리의 한 단계.
class ReminderStep {
  /// 복약 시각으로부터의 지연.
  final Duration delay;

  /// 이 단계에서 실제로 나갈 문구. 단계마다 문구가 바뀐다.
  final String Function(DoseSlot slot) message;

  final ReminderChannel channel;

  /// 어르신이 아니라 보호자에게 가는 단계인가.
  final bool toGuardian;

  const ReminderStep({
    required this.delay,
    required this.message,
    required this.channel,
    this.toGuardian = false,
  });
}

/// 예약된 알림 한 건.
class ScheduledReminder {
  final DoseSlot slot;
  final DateTime fireAt;
  final String message;
  final ReminderChannel channel;
  final bool toGuardian;

  const ScheduledReminder({
    required this.slot,
    required this.fireAt,
    required this.message,
    required this.channel,
    required this.toGuardian,
  });
}

/// 재알림 사다리 (5c).
///
/// 복약 시각을 저녁 6시로 가정하면:
///
/// | 시각 | 동작 | 채널 |
/// | --- | --- | --- |
/// | 6:00 | "저녁 약 드실 시간이에요" | 잠금화면 + 소리 |
/// | 6:15 | "아직 저녁 약을 안 드셨어요" | 잠금화면 + 소리 + 진동 |
/// | 6:45 | "저녁 약을 꼭 드셔야 해요" | 무음 모드에서도 울림 |
/// | 7:00 | 보호자에게 "확인이 필요해요" | 보호자 푸시 |
///
/// 규칙
/// - 어느 단계에서든 복약이 기록되면 이후 단계는 **전부 취소**된다.
/// - "30분 뒤에 다시"를 누르면 사다리 전체가 30분 뒤로 밀린다(단계 스킵 없음).
/// - 보호자 통보 단계는 **기본 켜짐**이고, 끄려면 보호자 동의가 필요하다.
abstract final class ReminderLadder {
  static const Duration snoozeInterval = Duration(minutes: 30);

  static final List<ReminderStep> steps = <ReminderStep>[
    ReminderStep(
      delay: Duration.zero,
      message: (slot) => '${slot.label} 약 드실 시간이에요',
      channel: ReminderChannel.lockScreenSound,
    ),
    ReminderStep(
      delay: const Duration(minutes: 15),
      message: (slot) => '아직 ${slot.label} 약을 안 드셨어요',
      channel: ReminderChannel.lockScreenSoundVibration,
    ),
    ReminderStep(
      delay: const Duration(minutes: 45),
      message: (slot) => '${slot.label} 약을 꼭 드셔야 해요',
      channel: ReminderChannel.criticalAlert,
    ),
    ReminderStep(
      delay: const Duration(minutes: 60),
      message: (slot) => '어머니가 ${slot.label} 약을 드시지 않았어요',
      channel: ReminderChannel.guardianPush,
      toGuardian: true,
    ),
  ];

  /// 한 시간대의 알림 예약 목록을 만든다.
  /// [snoozeCount]만큼 사다리 전체가 30분씩 뒤로 밀린다.
  static List<ScheduledReminder> planFor(
    DoseSlot slot,
    DateTime doseTime, {
    int snoozeCount = 0,
    bool notifyGuardian = true,
  }) {
    final shift = snoozeInterval * snoozeCount;
    return [
      for (final step in steps)
        if (notifyGuardian || !step.toGuardian)
          ScheduledReminder(
            slot: slot,
            fireAt: doseTime.add(step.delay).add(shift),
            message: step.message(slot),
            channel: step.channel,
            toGuardian: step.toGuardian,
          ),
    ];
  }
}

/// 실제 알림을 거는 통로.
///
/// 화면 코드는 이 인터페이스만 알고, 플랫폼 구현은 아래에서 갈아 끼운다.
// TODO: iOS Notification Content Extension + Actionable Notification,
//       Android Notification Action + custom layout으로 구현한다.
//       액션 탭 시 앱 실행 없이 백그라운드로 기록되어야 한다.
abstract interface class ReminderScheduler {
  Future<void> schedule(List<ScheduledReminder> reminders);

  /// 복약이 기록되면 그 시간대의 남은 단계를 전부 취소한다.
  Future<void> cancelSlot(DoseSlot slot);
}

/// 플랫폼 연결 전까지 쓰는 메모리 구현. 예약 내역을 들고만 있는다.
class InMemoryReminderScheduler implements ReminderScheduler {
  final Map<DoseSlot, List<ScheduledReminder>> _scheduled = {};

  Map<DoseSlot, List<ScheduledReminder>> get scheduled =>
      Map.unmodifiable(_scheduled);

  @override
  Future<void> schedule(List<ScheduledReminder> reminders) async {
    for (final reminder in reminders) {
      _scheduled.putIfAbsent(reminder.slot, () => []).add(reminder);
    }
  }

  @override
  Future<void> cancelSlot(DoseSlot slot) async {
    _scheduled.remove(slot);
  }
}
