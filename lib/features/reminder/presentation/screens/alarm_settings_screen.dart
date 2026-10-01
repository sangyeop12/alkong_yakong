import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_feedback.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../../core/widgets/senior_wheel.dart';
import '../../../medication/application/medication_controller.dart';
import '../../application/alarm_preferences.dart';
import '../../application/reminder_notifications.dart';

/// 32 · 복약 알림.
///
/// **소리로 알려주기만 한다.** 말로 대답해서 기록하는 기능은 없다 —
/// 잘못 들으면 그대로 오기록이 되기 때문이다.
///
/// 알림 시각은 몇 개든 둘 수 있다. ＋로 더하고 휴지통으로 지운다.
/// 고른 값은 저장돼서 내 정보 목록의 한 줄과 같이 바뀐다.
class AlarmSettingsScreen extends ConsumerStatefulWidget {
  const AlarmSettingsScreen({super.key});

  @override
  ConsumerState<AlarmSettingsScreen> createState() =>
      _AlarmSettingsScreenState();
}

class _AlarmSettingsScreenState extends ConsumerState<AlarmSettingsScreen> {
  /// 휴지통을 누르면 켜진다. 시간 칸이 밀리고 빼기 단추가 나온다.
  bool _editing = false;

  Future<void> _addHour(
    BuildContext context,
    AlarmPreferences prefs,
    AlarmPreferencesController notifier,
  ) async {
    if (prefs.hours.length >= AlarmPreferences.maxHours) {
      showSeniorSnackbar(
        context,
        '알림 시간은 ${AlarmPreferences.maxHours}개까지 둘 수 있어요',
      );
      return;
    }
    final picked = await showSeniorTimeWheel(
      context: context,
      title: '알림 시간을 더할까요?',
      initialHour: 9,
    );
    if (picked == null || !context.mounted) return;
    if (prefs.hours.contains(picked)) {
      showSeniorSnackbar(
        context,
        '이미 ${AlarmPreferences.clock(picked)} 알림이 있어요',
      );
      return;
    }
    notifier.update(prefs.withHour(picked));
  }

  Future<void> _changeHour(
    BuildContext context,
    AlarmPreferences prefs,
    AlarmPreferencesController notifier,
    int hour,
  ) async {
    final picked = await showSeniorTimeWheel(
      context: context,
      title: '몇 시에 알려드릴까요?',
      initialHour: hour,
    );
    if (picked == null || picked == hour || !context.mounted) return;
    if (prefs.hours.contains(picked)) {
      showSeniorSnackbar(
        context,
        '이미 ${AlarmPreferences.clock(picked)} 알림이 있어요',
      );
      return;
    }
    notifier.update(prefs.replaceHour(hour, picked));
  }

  /// 휴지통을 누르면 지우는 중으로 들어가고, 한 번 더 누르면 나온다.
  void _toggleEditing(BuildContext context, AlarmPreferences prefs) {
    if (!_editing && prefs.hours.length <= 1) {
      showSeniorSnackbar(context, '알림 시간은 적어도 하나는 있어야 해요');
      return;
    }
    setState(() => _editing = !_editing);
  }

  /// 빼기 단추로 그 자리 시간을 바로 지운다.
  void _removeHour(
    BuildContext context,
    AlarmPreferences prefs,
    AlarmPreferencesController notifier,
    int hour,
  ) {
    if (prefs.hours.length <= 1) {
      showSeniorSnackbar(context, '알림 시간은 적어도 하나는 있어야 해요');
      return;
    }
    notifier.update(prefs.withoutHour(hour));
    showSeniorSnackbar(context, '${AlarmPreferences.clock(hour)} 알림을 지웠어요');
    // 하나만 남으면 더 지울 것이 없다. 지우는 중에서 나온다.
    if (prefs.hours.length - 1 <= 1) setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final today = ref.watch(medicationProvider);
    final prefs = ref.watch(alarmPreferencesProvider);
    final notifier = ref.read(alarmPreferencesProvider.notifier);
    final notifications = ref.read(reminderNotificationsProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const SeniorBackHeader(title: '복약 알림'),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    child: Row(
                      children: [
                        ExcludeSemantics(
                          child: Icon(
                            TablerIcons.speakerphone,
                            size: 26,
                            color: prefs.autoAlarm
                                ? AppColors.point
                                : AppColors.textTertiary,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '약 시간이 되면 자동으로 말해드려요',
                                style: AppText.cardTitle(size: 19),
                              ),
                              Text(
                                prefs.autoAlarm
                                    ? '켜짐 · ${prefs.hours.map(AlarmPreferences.clock).join(', ')}에 소리로 알려드려요'
                                    : '꺼짐 · 화면에서 눌러야 들을 수 있어요',
                                style: AppText.caption(size: 17),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        SeniorToggle(
                          value: prefs.autoAlarm,
                          semanticLabel: '자동으로 소리 알림',
                          onChanged: (v) async {
                            final next = prefs.copyWith(autoAlarm: v);
                            notifier.update(next);
                            if (!v) return;
                            // 켜는 순간에 묻는다. 무엇을 허락하는지 알고 누르게.
                            final allowed = await notifications
                                .requestPermissions(exactAlarm: true);
                            if (!allowed) {
                              if (!context.mounted) return;
                              showSeniorSnackbar(
                                context,
                                '전화기 설정에서 알림을 허용해 주세요. '
                                '그래야 약 시간에 소리가 나요.',
                                error: true,
                              );
                              return;
                            }
                            // 정확한 알람을 방금 허락받았을 수 있으니 다시 맞춘다.
                            await notifications.sync(next);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '알림 시간',
                                style: AppText.label(
                                  size: 18,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ),
                            if (!_editing) ...[
                              _IconBox(
                                icon: TablerIcons.plus,
                                label: '알림 시간 더하기',
                                onTap: () => _addHour(context, prefs, notifier),
                              ),
                              const SizedBox(width: 10),
                            ],
                            _IconBox(
                              icon: _editing
                                  ? TablerIcons.check
                                  : TablerIcons.trash,
                              label: _editing ? '다 지웠어요' : '알림 시간 지우기',
                              color: _editing
                                  ? AppColors.point
                                  : AppColors.danger,
                              onTap: () => _toggleEditing(context, prefs),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        for (int i = 0; i < prefs.hours.length; i++) ...[
                          if (i > 0) const SizedBox(height: 10),
                          _TimeRow(
                            time: AlarmPreferences.clock(prefs.hours[i]),
                            editing: _editing,
                            onChange: () => _changeHour(
                              context,
                              prefs,
                              notifier,
                              prefs.hours[i],
                            ),
                            onRemove: () => _removeHour(
                              context,
                              prefs,
                              notifier,
                              prefs.hours[i],
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Text(
                          '이 시간이 되면 화면이 꺼져 있어도 '
                          '전화기가 먼저 알려드려요.',
                          style: AppText.caption(size: 16),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 4,
                    ),
                    child: Column(
                      children: [
                        _LadderRow(
                          title: '못 들으셨으면 10분 뒤에 한 번 더',
                          description: '최대 두 번까지 다시 알려드려요',
                          value: prefs.repeatOnce,
                          onChanged: (v) =>
                              notifier.update(prefs.copyWith(repeatOnce: v)),
                        ),
                        const SeniorDivider(),
                        _LadderRow(
                          title: '30분 지나면 가족에게 알림',
                          description: today.hasGuardian
                              ? '${today.guardianTitle}에게만 전해집니다'
                              : '등록된 가족이 없어요 · 내 정보에서 초대할 수 있어요',
                          value: prefs.tellGuardian,
                          onChanged: (v) =>
                              notifier.update(prefs.copyWith(tellGuardian: v)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 카드 머리의 네모 단추. ＋와 휴지통 둘뿐이라 글자 없이 둔다.
class _IconBox extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _IconBox({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = AppColors.textPrimary,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 60,
          height: 60,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.strongLine, width: 2),
          ),
          child: ExcludeSemantics(child: Icon(icon, size: 28, color: color)),
        ),
      ),
    );
  }
}

/// 알림 시간 한 줄. 회색 칸 안에 큰 시각, 오른쪽에 "바꾸기 >".
///
/// 지우는 중에는 칸이 왼쪽으로 밀리고 빈 자리에 빼기 단추가 선다.
class _TimeRow extends StatelessWidget {
  final String time;
  final bool editing;
  final VoidCallback onChange;
  final VoidCallback onRemove;

  const _TimeRow({
    required this.time,
    required this.onChange,
    required this.onRemove,
    this.editing = false,
  });

  /// 빼기 단추가 차지하는 폭. 옆 여백까지 합친 값이다.
  static const double _removeWidth = 74;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Semantics(
            button: true,
            label: '$time · 바꾸기',
            child: ExcludeSemantics(
              child: GestureDetector(
                // 지우는 중에는 시간을 바꾸지 않는다. 한 번에 한 가지만.
                onTap: editing ? null : onChange,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  constraints: const BoxConstraints(minHeight: 72),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.bg,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          time,
                          style: AppText.screenTitle(size: 23),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!editing) ...[
                        const SizedBox(width: 10),
                        Text('바꾸기', style: AppText.label(size: 17)),
                        const SizedBox(width: 4),
                        const SeniorChevron(),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        // 밀려난 자리에 빼기 단추가 미끄러져 들어온다.
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          width: editing ? _removeWidth : 0,
          height: 72,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.centerRight,
              maxWidth: _removeWidth,
              child: Padding(
                padding: const EdgeInsets.only(left: 14),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: editing ? 1 : 0,
                  child: Semantics(
                    button: true,
                    label: '$time 알림 빼기',
                    child: ExcludeSemantics(
                      child: GestureDetector(
                        onTap: editing ? onRemove : null,
                        child: Container(
                          width: 60,
                          height: 60,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            color: AppColors.danger,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            TablerIcons.minus,
                            size: 30,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LadderRow extends StatelessWidget {
  final String title;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _LadderRow({
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(vertical: 17),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.cardTitle(size: 19)),
                Text(description, style: AppText.caption(size: 17)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SeniorToggle(
            value: value,
            semanticLabel: title,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
