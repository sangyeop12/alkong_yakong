import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_header.dart';

/// 보호자 · 알림 받는 방법 (프로토타입 95).
///
/// 어떻게 받을지 · 언제 알릴지 · 밤 시간을 켜고 끈다.
/// 고른 값은 이 전화기에 저장한다.
class GuardianAlertPrefsScreen extends StatefulWidget {
  const GuardianAlertPrefsScreen({super.key});

  @override
  State<GuardianAlertPrefsScreen> createState() =>
      _GuardianAlertPrefsScreenState();
}

class _GuardianAlertPrefsScreenState extends State<GuardianAlertPrefsScreen> {
  static const _keys = <String, bool>{
    'guardian_alert_push': true,
    'guardian_alert_sound': true,
    'guardian_alert_sms': true,
    'guardian_alert_missed': true,
    'guardian_alert_heart': true,
    'guardian_alert_new_medicine': false,
    'guardian_alert_quiet_night': true,
  };

  final Map<String, bool> _values = Map.of(_keys);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      for (final entry in _keys.entries) {
        _values[entry.key] = prefs.getBool(entry.key) ?? entry.value;
      }
    });
  }

  Future<void> _set(String key, bool value) async {
    setState(() => _values[key] = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const SeniorBackHeader(title: '알림 받는 방법', alignStart: true),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _group('어떻게 받을까요', const {
                    'guardian_alert_push': '앱 알림',
                    'guardian_alert_sound': '소리',
                    'guardian_alert_sms': '문자',
                  }),
                  const SizedBox(height: 22),
                  _group('언제 알릴까요', const {
                    'guardian_alert_missed': '약을 안 드셨을 때',
                    'guardian_alert_heart': '심박수가 빠를 때',
                    'guardian_alert_new_medicine': '새 약이 등록됐을 때',
                  }),
                  const SizedBox(height: 22),
                  _group('밤 시간', const {
                    'guardian_alert_quiet_night': '밤 10시~7시 소리 끄기',
                  }),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _group(String title, Map<String, String> rows) {
    final keys = rows.keys.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: AppText.label(size: 18)),
        const SizedBox(height: 8),
        SeniorCard(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 4),
          child: Column(
            children: [
              for (int i = 0; i < keys.length; i++) ...[
                if (i > 0) const SeniorDivider(),
                _SwitchRow(
                  label: rows[keys[i]]!,
                  value: _values[keys[i]] ?? false,
                  onChanged: (value) => _set(keys[i], value),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(child: Text(label, style: AppText.cardTitle(size: 21))),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: Colors.white,
            activeTrackColor: AppColors.point,
            inactiveThumbColor: Colors.white,
            inactiveTrackColor: AppColors.strongLine,
            trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
            // 머티리얼 기본값은 꺼짐일 때 안쪽 동그라미를 줄인다. 켜고 끌 때
            // 크기까지 바뀌면 손가락이 짚을 자리가 흔들린다. 보이지 않는
            // 아이콘을 넣어 두 상태의 동그라미를 같은 크기로 묶는다.
            thumbIcon: WidgetStateProperty.all(
              const Icon(Icons.circle, size: 0, color: Colors.transparent),
            ),
          ),
        ],
      ),
    );
  }
}
