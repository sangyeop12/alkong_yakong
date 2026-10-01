import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/mode_badge.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_feedback.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../medication/application/medication_controller.dart';
import '../../../reminder/application/reminder_notifications.dart';
import '../../../medication/domain/medication_models.dart';
import '../../../medication/presentation/widgets/dose_flow_sheets.dart';
import '../../../easy_flow/domain/easy_flow.dart';
import '../../../easy_flow/presentation/easy_flow_shell.dart';
import '../../../medication/presentation/widgets/dose_guard_sheets.dart';
import '../../../profile/application/current_user_controller.dart';

/// 12 / 15 · 오늘 · 홈.
///
/// **주인공은 "지금 드실 약" 하나.** 나머지는 아래로 밀린다.
class PatientHomeScreen extends ConsumerStatefulWidget {
  /// 기록 탭으로 이동.
  final VoidCallback? onOpenRecord;

  /// 심박수 관리 화면으로 이동.
  final VoidCallback? onOpenHeartbeat;

  /// 약 목록 · AI 약사 · 처방전 넣기로 이동.
  final VoidCallback? onOpenMedicines;
  final VoidCallback? onOpenChat;
  final VoidCallback? onOpenPrescription;

  /// 약 하나를 눌렀을 때 설명 화면으로.
  final void Function(Medicine medicine)? onOpenDrug;

  /// "먹었어요" 뒤 심박수를 재러 갈 때. 방금 기록한 시간대를 함께 넘긴다.
  final void Function(DoseSlot slot)? onMeasure;

  /// 복약을 기록한 뒤 완료 화면으로. 방금 기록한 시간대를 함께 넘긴다.
  final void Function(DoseSlot slot)? onDone;

  /// 쉬운 모드인지. 헤더의 아바타가 "메뉴" 버튼으로 바뀌고
  /// 스크롤 아래 여백이 하단 바만큼 늘어난다.
  final bool easyMode;

  /// 쉬운 모드에서 메뉴를 열 때.
  final VoidCallback? onOpenMenu;

  const PatientHomeScreen({
    super.key,
    this.onOpenRecord,
    this.onOpenHeartbeat,
    this.onOpenMedicines,
    this.onOpenChat,
    this.onOpenPrescription,
    this.onOpenDrug,
    this.onMeasure,
    this.onDone,
    this.easyMode = false,
    this.onOpenMenu,
  });

  @override
  ConsumerState<PatientHomeScreen> createState() => _PatientHomeScreenState();
}

class _PatientHomeScreenState extends ConsumerState<PatientHomeScreen> {
  /// 재알림을 미뤘을 때 상단에 뜨는 안내.
  String? _snoozeNotice;

  /// 방금 기록한 시간대. 파란 띠로 알리고, X를 누르면 사라진다.
  DoseSlot? _recordedSlot;

  @override
  void initState() {
    super.initState();
    // 잔여일이 0이면 홈에 들어오는 순간 리필 시트를 연다. 하루 한 번만.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAskRefill());
    ReminderNotifications.pendingAction.addListener(_onNotificationAction);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _onNotificationAction(),
    );
  }

  @override
  void dispose() {
    ReminderNotifications.pendingAction.removeListener(_onNotificationAction);
    super.dispose();
  }

  /// 잠금화면 알림에서 누른 단추를 여기서 마무리한다 (프로토타입 40번).
  void _onNotificationAction() {
    final action = ReminderNotifications.pendingAction.value;
    if (action == null || !mounted) return;
    ReminderNotifications.pendingAction.value = null;
    final next = ref.read(medicationProvider).nextDose;
    if (next == null) return;
    if (action == ReminderNotifications.takeActionId) {
      unawaited(_take(next.slot));
    } else if (action == ReminderNotifications.snoozeActionId) {
      _snooze(next.slot);
    }
  }

  Future<void> _maybeAskRefill() async {
    final controller = ref.read(medicationProvider.notifier);
    if (!mounted || !controller.shouldAskRefill) return;
    controller.markRefillAsked();

    final today = ref.read(medicationProvider);
    final startedOn = today.courseStartedOn!;
    final choice = await showRefillSheet(
      context,
      startedOn: '${startedOn.month}월 ${startedOn.day}일',
      totalDays: today.courseTotalDays!,
    );
    if (!mounted) return;
    switch (choice) {
      case RefillChoice.addPrescription:
        widget.onOpenPrescription?.call();
      case RefillChoice.tellFamily:
        showSeniorSnackbar(
          context,
          '${ref.read(medicationProvider).guardianTitle}에게 알렸어요',
        );
      case RefillChoice.askTomorrow:
        break;
    }
  }

  /// "먹었어요" — 바로 기록하지 않고 센서 착용부터 묻는다.
  Future<void> _take(DoseSlot slot) async {
    final controller = ref.read(medicationProvider.notifier);

    // 이미 기록된 시간대는 묻기 전에 막는다. 사후 안내가 아니라 사전 차단이다.
    if (ref.read(medicationProvider).doseOf(slot).taken) {
      await _showDuplicateGuard(slot);
      return;
    }

    final choice = await showWearSensorSheet(context);
    if (!mounted || choice == WearChoice.cancel) return;

    final outcome = await controller.take(slot);
    if (!mounted) return;

    switch (outcome) {
      case DoseCheckOutcome.alreadyTaken:
        await _showDuplicateGuard(slot);
      case DoseCheckOutcome.tooLate:
        final proceed = await showLateDoseSheet(context: context, slot: slot);
        if (proceed && mounted) {
          await controller.takeAnyway(slot);
          if (!mounted) return;
          _afterRecord(choice, slot);
        }
      case DoseCheckOutcome.recorded:
        _afterRecord(choice, slot);
    }
  }

  void _afterRecord(WearChoice choice, DoseSlot slot) {
    // 기록하고 나서도 오늘 화면에 남는다. 화면이 바뀌면 방금 무엇을
    // 눌렀는지 놓친다. 대신 맨 위에 파란 띠로 알린다.
    setState(() {
      _recordedSlot = slot;
      _snoozeNotice = null;
    });
    if (choice == WearChoice.wearingAndMeasure) {
      widget.onMeasure?.call(slot);
    } else {
      widget.onDone?.call(slot);
    }
  }

  Future<void> _showDuplicateGuard(DoseSlot slot) async {
    final dose = ref.read(medicationProvider).doseOf(slot);
    await showDuplicateDoseSheet(
      context: context,
      dose: dose,
      onUndo: () => ref.read(medicationProvider.notifier).undo(slot),
    );
  }

  void _undo(DoseSlot slot) {
    ref.read(medicationProvider.notifier).undo(slot);
    setState(() => _recordedSlot = null);
  }

  void _snooze(DoseSlot slot) {
    final until = ref.read(medicationProvider.notifier).snooze(slot);
    setState(() => _snoozeNotice = '${DoseSlot.absoluteTime(until)}에 다시 알려드려요');
  }

  /// 오늘 화면의 본체 — 지금 드실 약 카드 한 장.
  ///
  /// 지난 복약은 카드 안 "오늘 다른 약"이 말해 준다. 시간 축 막대와 행을
  /// 따로 쌓지 않는다 — 한 화면에 할 일 하나만 둔다.
  Widget _doseCard(TodayMedication today, DoseEntry? next) {
    if (next != null) {
      return _NextDoseCard(
        today: today,
        dose: next,
        onTake: () => _take(next.slot),
        onSnooze: () => _snooze(next.slot),
        onOpenDrug: widget.onOpenDrug,
      );
    }
    return _AllDoneCard(
      today: today,
      onUndo: () => _undo(_recordedSlot ?? today.doses.last.slot),
      onOpenDrug: widget.onOpenDrug,
    );
  }

  /// 오늘 심박수를 잰 시간대. 여러 번 쟀으면 가장 나중 것을 쓴다.
  static DoseEntry? _todayHeartCheck(TodayMedication today) {
    DoseEntry? found;
    for (final dose in today.doses) {
      if (dose.heartCheck != null) found = dose;
    }
    return found;
  }

  @override
  Widget build(BuildContext context) {
    final today = ref.watch(medicationProvider);
    final next = today.nextDose;
    final now = DateTime.now();

    return Column(
      children: [
        HomeTopBar(
          userName: ref.watch(currentUserNameProvider),
          date: now,
          easyMode: widget.easyMode,
          onOpenMenu: widget.onOpenMenu,
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              16,
              20,
              // 쉬운 모드의 하단 바가 마지막 카드를 가리지 않게 한다.
              widget.easyMode ? kEasyBarScrollPadding : 28,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_snoozeNotice != null) ...[
                  _SnoozeNotice(text: _snoozeNotice!),
                  const SizedBox(height: 12),
                ],
                // 상담과 오늘 잰 심박수는 약 카드 위에 둔다.
                _TopShortcuts(
                  heartCheck: _todayHeartCheck(today)?.heartCheck,
                  heartSlotLabel: _todayHeartCheck(today)?.slot.label,
                  heartRate: today.heartRate,
                  onOpenChat: widget.onOpenChat,
                  onOpenHeartbeat: widget.onOpenHeartbeat,
                ),
                const SizedBox(height: 12),
                if (_recordedSlot != null) ...[
                  _RecordedBanner(
                    slot: _recordedSlot!,
                    onClose: () => setState(() => _recordedSlot = null),
                  ),
                  const SizedBox(height: 12),
                ],
                if (today.doses.isEmpty)
                  SeniorCard(
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      children: [
                        Text('등록된 약이 없어요', style: AppText.cardTitle(size: 22)),
                        const SizedBox(height: 8),
                        Text(
                          '처방전 사진을 찍으면 오늘 먹을 약을 알려드려요.',
                          textAlign: TextAlign.center,
                          style: AppText.body(color: AppColors.textSecondary),
                        ),
                        const SizedBox(height: 14),
                        SeniorButton(
                          label: '처방전 등록하기',
                          onPressed: widget.onOpenPrescription,
                        ),
                      ],
                    ),
                  )
                else
                  _doseCard(today, next),
                const SizedBox(height: 12),
                // 바로가기는 접지 않는다. 한 번 더 눌러야 나오는 기능은
                // 없는 것과 같다 — 어르신은 접힌 줄을 열어 보지 않는다.
                _BottomShortcuts(
                  onOpenMedicines: widget.onOpenMedicines,
                  onOpenPrescription: widget.onOpenPrescription,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 날짜 칩 + 모드 배지 + 아바타.
/// 오늘 화면 맨 위 띠 — 날짜·화면 모드·내 정보. 복약 완료 화면도 같이 쓴다.
class HomeTopBar extends StatelessWidget {
  final String userName;
  final DateTime date;
  final bool easyMode;
  final VoidCallback? onOpenMenu;

  const HomeTopBar({
    super.key,
    required this.userName,
    required this.date,
    this.easyMode = false,
    this.onOpenMenu,
  });

  @override
  Widget build(BuildContext context) {
    return SeniorHeader(
      child: Row(
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.bg,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '${date.month}월 ${date.day}일',
                    style: AppText.cardTitle(
                      size: 21,
                      color: AppColors.point,
                      weight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '오늘',
                    style: AppText.cardTitle(size: 21, weight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          const ModeBadge(),
          const SizedBox(width: 10),
          if (easyMode && onOpenMenu != null)
            EasyMenuButton(onTap: onOpenMenu!)
          else
            InitialAvatar(name: userName, size: 52, background: AppColors.bg),
        ],
      ),
    );
  }
}

class _SnoozeNotice extends StatelessWidget {
  final String text;
  const _SnoozeNotice({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: AppColors.pointTint,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: AppText.label(size: 18.5, color: AppColors.pointInk),
      ),
    );
  }
}

/// 지금 드실 약 — 이 화면의 주인공.
class _NextDoseCard extends StatelessWidget {
  final TodayMedication today;
  final DoseEntry dose;
  final VoidCallback onTake;
  final VoidCallback onSnooze;
  final void Function(Medicine)? onOpenDrug;

  const _NextDoseCard({
    required this.today,
    required this.dose,
    required this.onTake,
    required this.onSnooze,
    required this.onOpenDrug,
  });

  int _dailyFrequency(Medicine medicine) =>
      medicine.frequencyPerDay ??
      today.doses
          .where(
            (entry) => entry.medicines.any(
              (candidate) =>
                  _medicineIdentity(candidate) == _medicineIdentity(medicine),
            ),
          )
          .length;

  @override
  Widget build(BuildContext context) {
    final others = today.doses.where((d) => d.slot != dose.slot).toList();
    final daysLeft = today.daysLeft;
    return SeniorCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (daysLeft != null) ...[
            DaysLeftRow(daysLeft: daysLeft, phrase: today.daysLeftPhrase),
            const SizedBox(height: 12),
          ],
          LabelValueRow(
            label: Text(dose.slot.spokenTime, style: AppText.bigTime(size: 36)),
            value: Text(
              '눌러서 설명 보기',
              textAlign: TextAlign.right,
              style: AppText.label(size: 16.5, color: AppColors.textTertiary),
            ),
          ),
          const SizedBox(height: 12),
          for (int i = 0; i < dose.medicines.length; i++) ...[
            if (i > 0) const SeniorDivider(),
            _MedicineRow(
              medicine: dose.medicines[i],
              frequencyPerDay: _dailyFrequency(dose.medicines[i]),
              onTap: onOpenDrug == null
                  ? null
                  : () => onOpenDrug!(dose.medicines[i]),
            ),
          ],
          const SizedBox(height: 12),
          SeniorButton(label: '먹었어요', onPressed: onTake),
          const SizedBox(height: 10),
          SeniorButton(
            label: '30분 뒤에 다시 알려주기',
            kind: SeniorButtonKind.secondary,
            minHeight: 62,
            fontSize: 20,
            onPressed: onSnooze,
          ),
          if (others.isNotEmpty) ...[
            const SizedBox(height: 12),
            _OtherDosesBlock(doses: others),
          ],
        ],
      ),
    );
  }
}

/// 약 한 줄 — 사진, 이름, 짧은 분류, 하루 횟수.
class _MedicineRow extends StatelessWidget {
  final Medicine medicine;
  final int frequencyPerDay;
  final VoidCallback? onTap;

  const _MedicineRow({
    required this.medicine,
    required this.frequencyPerDay,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            PillPhoto(size: 60),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          medicine.displayName,
                          style: AppText.cardTitle(size: 21),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '하루 $frequencyPerDay회',
                        style: AppText.cardTitle(
                          size: 20,
                          color: AppColors.point,
                        ),
                      ),
                      if (onTap != null) ...[
                        const SizedBox(width: 4),
                        const SeniorChevron(),
                      ],
                    ],
                  ),
                  if (medicine.effect != null)
                    Text(medicine.effect!, style: AppText.caption(size: 16.5)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 지금 시간대가 아닌 오늘 약. 먹었어요 단추는 두지 않는다.
class _OtherDosesBlock extends StatelessWidget {
  final List<DoseEntry> doses;
  const _OtherDosesBlock({required this.doses});

  List<_OtherMedicineSchedule> get _medicineSchedules {
    final grouped = <String, _OtherMedicineSchedule>{};
    for (final dose in doses) {
      for (final medicine in dose.medicines) {
        final key = _medicineIdentity(medicine);
        final schedule = grouped.putIfAbsent(
          key,
          () => _OtherMedicineSchedule(medicine),
        );
        schedule.addDose(dose);
      }
    }
    return grouped.values.toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.sunken,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('오늘 다른 약', style: AppText.label(size: 17.5)),
          const SizedBox(height: 10),
          for (final schedule in _medicineSchedules)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  const PillPhoto(size: 38),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          schedule.medicine.displayName,
                          style: AppText.label(
                            size: 18,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        if (schedule.medicine.effect != null)
                          Text(
                            schedule.medicine.effect!,
                            style: AppText.caption(size: 16.5),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        schedule.statusLabel,
                        style: AppText.cardTitle(
                          size: 16.5,
                          color: schedule.allTaken
                              ? AppColors.point
                              : AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

String _medicineIdentity(Medicine medicine) {
  final code = medicine.medicineCode?.trim() ?? '';
  if (code.isNotEmpty) return 'code:$code';
  final normalizedName = medicine.displayName
      .replaceAll(RegExp(r'\s+'), '')
      .toLowerCase();
  return 'name:$normalizedName';
}

class _OtherMedicineSchedule {
  final Medicine medicine;
  final List<DoseEntry> _doses = [];

  _OtherMedicineSchedule(this.medicine);

  void addDose(DoseEntry dose) {
    if (_doses.any((entry) => entry.slot == dose.slot)) return;
    _doses.add(dose);
  }

  bool get allTaken => _doses.isNotEmpty && _doses.every((dose) => dose.taken);

  String get statusLabel {
    final taken = _doses.where((dose) => dose.taken).toList(growable: false);
    final pending = _doses.where((dose) => !dose.taken).toList(growable: false);
    String slots(List<DoseEntry> entries) =>
        entries.map((entry) => entry.slot.label).join('·');

    if (pending.isEmpty) return '${slots(taken)} ✓';
    if (taken.isEmpty) return '${slots(pending)}에 있어요';
    return '${slots(taken)} ✓ · ${slots(pending)} 예정';
  }
}

/// 오늘 약을 다 드신 뒤의 카드.
/// 방금 기록했다고 알리는 파란 띠 (프로토타입 18번).
///
/// 화면을 갈아 끼우지 않고 여기서 알린다. X를 누르면 사라진다.
class _RecordedBanner extends StatelessWidget {
  final DoseSlot slot;
  final VoidCallback onClose;

  const _RecordedBanner({required this.slot, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: AppColors.point,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.pointPressed,
              shape: BoxShape.circle,
            ),
            child: Text(
              '✓',
              style: AppText.cardTitle(size: 22, color: Colors.white),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '잘하셨어요',
                  style: AppText.cardTitle(size: 22, color: Colors.white),
                ),
                Text(
                  '${slot.label} 약을 기록했어요',
                  style: AppText.caption(
                    size: 17,
                    color: AppColors.onPointMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Semantics(
            button: true,
            label: '알림 닫기',
            child: ExcludeSemantics(
              child: GestureDetector(
                onTap: onClose,
                child: Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.pointPressed,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    size: 26,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AllDoneCard extends StatelessWidget {
  final TodayMedication today;
  final VoidCallback onUndo;
  final void Function(Medicine medicine)? onOpenDrug;

  const _AllDoneCard({
    required this.today,
    required this.onUndo,
    required this.onOpenDrug,
  });

  /// 오늘 드신 약. 같은 약이 여러 번 나오면 한 번만 적는다.
  List<Medicine> get _takenMedicines {
    final seen = <String>{};
    final medicines = <Medicine>[];
    for (final dose in today.doses) {
      if (!dose.taken) continue;
      for (final medicine in dose.medicines) {
        if (seen.add(medicine.displayName)) medicines.add(medicine);
      }
    }
    return medicines;
  }

  @override
  Widget build(BuildContext context) {
    final daysLeft = today.daysLeft;
    final medicines = _takenMedicines;
    return SeniorCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.pointTint,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Text(
                  '✓',
                  style: AppText.cardTitle(size: 22, color: AppColors.point),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('오늘 약 다 드셨어요', style: AppText.cardTitle(size: 22)),
                    Text(
                      '다음 약은 내일 ${today.doses.first.slot.spokenTime}',
                      style: AppText.caption(size: 17.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (daysLeft != null) ...[
            DaysLeftRow(daysLeft: daysLeft, phrase: today.daysLeftPhrase),
            const SizedBox(height: 12),
          ],
          SeniorButton(
            label: '잘못 눌렀어요',
            kind: SeniorButtonKind.neutral,
            minHeight: 60,
            fontSize: 19,
            onPressed: onUndo,
          ),
          if (medicines.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              decoration: BoxDecoration(
                color: AppColors.sunken,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('오늘 드신 약 · 눌러서 설명 보기', style: AppText.caption(size: 16)),
                  for (final medicine in medicines)
                    _TakenMedicineRow(
                      medicine: medicine,
                      onTap: onOpenDrug == null
                          ? null
                          : () => onOpenDrug!(medicine),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 오늘 드신 약 한 줄 — 사진, 이름, 무슨 약인지.
class _TakenMedicineRow extends StatelessWidget {
  final Medicine medicine;
  final VoidCallback? onTap;

  const _TakenMedicineRow({required this.medicine, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final category = (medicine.easyCategory ?? '').trim();
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            const PillPhoto(size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    medicine.displayName,
                    style: AppText.cardTitle(size: 19),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (category.isNotEmpty)
                    Text(
                      category,
                      style: AppText.caption(size: 16),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 8),
              const SeniorChevron(),
            ],
          ],
        ),
      ),
    );
  }
}

/// 때문이다. 나머지 기능은 [_BottomShortcuts]로 화면 아래에 둔다.
class _TopShortcuts extends StatelessWidget {
  /// 오늘 약 전후로 잰 심박수. 잰 적이 없으면 null.
  final DoseHeartCheck? heartCheck;

  /// 그 심박수를 잰 시간대 이름 — "아침 심박수"처럼 앞에 붙인다.
  final String? heartSlotLabel;

  /// 가장 최근 심박수. 전후 기록이 없을 때만 쓴다.
  final int? heartRate;
  final VoidCallback? onOpenChat;
  final VoidCallback? onOpenHeartbeat;

  const _TopShortcuts({
    required this.heartCheck,
    required this.heartSlotLabel,
    required this.heartRate,
    required this.onOpenChat,
    required this.onOpenHeartbeat,
  });

  @override
  Widget build(BuildContext context) {
    final check = heartCheck;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _Shortcut(
              icon: TablerIcons.message_circle_question,
              label: 'AI 약사 상담',
              onTap: onOpenChat,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _Shortcut(
              icon: TablerIcons.heart,
              label: check == null || heartSlotLabel == null
                  ? '심박수'
                  : '$heartSlotLabel 심박수',
              trailing: check != null
                  ? '${check.before} → ${check.after}'
                  : (heartRate == null ? null : '$heartRate'),
              onTap: onOpenHeartbeat,
            ),
          ),
        ],
      ),
    );
  }
}

/// 화면 아래 바로가기 둘 — 약 목록과 처방전 넣기.
class _BottomShortcuts extends StatelessWidget {
  final VoidCallback? onOpenMedicines;
  final VoidCallback? onOpenPrescription;

  const _BottomShortcuts({
    required this.onOpenMedicines,
    required this.onOpenPrescription,
  });

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _Shortcut(
              icon: TablerIcons.pill,
              label: '내 약 목록',
              onTap: onOpenMedicines,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _Shortcut(
              // Rx 기호는 처방전으로 읽히지 않고 깨진 글자처럼 보인다.
              icon: TablerIcons.file_description,
              label: '처방전 넣기',
              onTap: onOpenPrescription,
            ),
          ),
        ],
      ),
    );
  }
}

class _Shortcut extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? trailing;
  final VoidCallback? onTap;

  const _Shortcut({
    required this.icon,
    required this.label,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SeniorCard(
      radius: 20,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.pointTint,
              borderRadius: BorderRadius.circular(13),
            ),
            child: ExcludeSemantics(
              child: Icon(icon, size: 26, color: AppColors.point),
            ),
          ),
          const SizedBox(height: 10),
          // 값은 이름 아래에 둔다. 한 줄에 나란히 두면 좁은 타일에서 잘린다.
          Text(label, style: AppText.cardTitle(size: 19)),
          if (trailing != null) ...[
            const SizedBox(height: 4),
            Text(
              trailing!,
              style: AppText.cardTitle(size: 21, color: AppColors.point),
            ),
          ],
        ],
      ),
    );
  }
}

/// 지난 복약 행 — 이미 드신 시간대.
///

/// 접힌 복약 행을 펼쳤을 때 나오는 약 목록.
///
