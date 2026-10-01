import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_feedback.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../medication/domain/medication_models.dart';
import '../../application/heart_sensor.dart';
import 'measure_screen.dart';

/// 25 · 폴라 센서.
///
/// 연결 상태를 한눈에 보여주고, **차는 방법 3단계**를 늘 같이 둔다.
/// 어르신이 센서를 못 차서 못 재는 경우가 실제로 가장 많다.
///
/// 연결·배터리·마지막 측정은 **[HeartSensor]가 말한 것만** 보여준다.
/// 기기가 아직 안 알려준 값은 "모른다"고 쓰고, 숫자를 채워 넣지 않는다.
class PolarScreen extends StatefulWidget {
  /// 밖에서 넣어 주는 센서. 없으면 이 화면이 하나 만들어 쓴다.
  final HeartSensor? sensor;

  const PolarScreen({super.key, this.sensor});

  @override
  State<PolarScreen> createState() => _PolarScreenState();
}

class _PolarScreenState extends State<PolarScreen> {
  late final bool _ownsSensor = widget.sensor == null;
  late final HeartSensor _sensor = widget.sensor ?? HeartSensor();

  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _sensor.addListener(_onSensor);
  }

  void _onSensor() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _sensor.removeListener(_onSensor);
    // 넘겨받은 센서는 연결을 끊지 않는다 — 재러 들어갈 때 다시 붙는 시간을
    // 아끼기 위해서다. 이 화면이 만든 센서만 이 화면이 치운다.
    if (_ownsSensor) _sensor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _sensor.status == HeartSensorStatus.streaming;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const SeniorBackHeader(title: '폴라 센서'),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StatusCard(connected: connected),
                  const SizedBox(height: 12),
                  if (connected) ...[
                    _InfoCard(sensor: _sensor),
                    const SizedBox(height: 16),
                    SeniorButton(
                      label: '지금 측정',
                      minHeight: 70,
                      fontSize: 24,
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => MeasureScreen(
                            sensor: _sensor,
                            returnToPreviousScreen: true,
                          ),
                        ),
                      ),
                    ),
                  ] else ...[
                    SeniorButton(
                      label: _searching ? '찾는 중이에요…' : '기기 찾기',
                      icon: TablerIcons.bluetooth,
                      minHeight: 70,
                      fontSize: 24,
                      onPressed: _searching ? null : _search,
                    ),
                  ],
                  const SizedBox(height: 12),
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 18,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('차는 방법', style: AppText.cardTitle(size: 20)),
                        const SizedBox(height: 14),
                        const NumberedSteps(
                          boxed: false,
                          steps: [
                            '센서 안쪽 두 군데를 물로 살짝 적셔주세요',
                            '가슴 아래, 명치 높이에 맞춰 차세요',
                            '약을 드시기 5분 전에 차 두시면 편해요',
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (connected) ...[
                    const SizedBox(height: 16),
                    SeniorButton(
                      label: '연결 끊기',
                      kind: SeniorButtonKind.dangerQuiet,
                      minHeight: 62,
                      fontSize: 20,
                      onPressed: () async {
                        // 화면 표시만 바꾸지 않는다. 실제로 끊는다.
                        await _sensor.stop();
                        if (!context.mounted) return;
                        showSeniorSnackbar(context, '센서 연결을 끊었어요');
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _search() async {
    setState(() => _searching = true);
    await _sensor.start();
    if (!mounted) return;
    setState(() => _searching = false);

    // 못 찾았는데 "찾았어요"라고 말하지 않는다.
    final found = _sensor.status == HeartSensorStatus.streaming;
    showSeniorSnackbar(
      context,
      found ? '폴라 센서를 찾았어요' : '센서를 찾지 못했어요. 단추를 한 번 눌러 주세요.',
      error: !found,
    );
  }
}

/// 큰 원 안의 하트 — 연결됐는지를 색으로 말한다.
class _StatusCard extends StatelessWidget {
  final bool connected;
  const _StatusCard({required this.connected});

  @override
  Widget build(BuildContext context) {
    return SeniorCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        children: [
          Container(
            width: 104,
            height: 104,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: connected ? AppColors.pointTint : AppColors.bg,
              shape: BoxShape.circle,
            ),
            child: ExcludeSemantics(
              child: Icon(
                TablerIcons.heart_filled,
                size: 56,
                color: connected ? AppColors.point : AppColors.strongLine,
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            connected ? '폴라 센서가 연결됐어요' : '폴라 센서가 연결되지 않았어요',
            textAlign: TextAlign.center,
            style: AppText.emphasis(size: 25),
          ),
          const SizedBox(height: 8),
          Text(
            connected ? '센서를 차고 계시면 약 드신 뒤 심박수를 측정합니다' : '센서를 차고 아래 버튼을 눌러주세요',
            textAlign: TextAlign.center,
            style: AppText.body(size: 18.5, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// 기기 이름 · 배터리 · 마지막 측정 — 모두 센서가 알려준 값.
class _InfoCard extends StatelessWidget {
  final HeartSensor sensor;
  const _InfoCard({required this.sensor});

  @override
  Widget build(BuildContext context) {
    final deviceId = sensor.deviceId;
    final lastReadAt = sensor.lastReadAt;
    return SeniorCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: Column(
        children: [
          _InfoRow(
            label: '기기 이름',
            value: Text(
              // 붙은 기기의 번호를 같이 적는다. 다른 기기 이름을 지어 쓰지 않는다.
              deviceId == null
                  ? 'Polar Verity Sense'
                  : 'Polar Verity Sense · $deviceId',
              style: AppText.label(size: 18, color: AppColors.textPrimary),
            ),
          ),
          const SeniorDivider(),
          _InfoRow(
            label: '배터리',
            value: _BatteryGauge(percent: sensor.battery),
          ),
          const SeniorDivider(),
          _InfoRow(
            label: '마지막 측정',
            value: Text(
              // 잰 적이 없으면 빈칸 대신 그렇다고 적는다.
              lastReadAt == null ? '아직 없어요' : DoseSlot.absoluteTime(lastReadAt),
              style: AppText.label(
                size: 18,
                color: lastReadAt == null
                    ? AppColors.textTertiary
                    : AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final Widget value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(vertical: 17),
      child: LabelValueRow(
        label: Text(
          label,
          style: AppText.label(size: 19, color: AppColors.textSecondary),
        ),
        value: value,
      ),
    );
  }
}

/// 남은 배터리를 눈금 없이 채움으로만 보여준다.
///
/// 기기가 아직 안 알려줬으면 **빈 막대에 0%를 그리지 않는다.**
/// 0%는 "다 닳았다"는 뜻이라 모른다는 것과 다르게 읽힌다.
class _BatteryGauge extends StatelessWidget {
  final int? percent;
  const _BatteryGauge({required this.percent});

  /// 20% 아래면 색으로도 알려 준다. 재는 중에 꺼지면 그 측정을 잃는다.
  bool get _low => percent != null && percent! <= 20;

  @override
  Widget build(BuildContext context) {
    final percent = this.percent;
    if (percent == null) {
      return Text(
        '아직 기기가 알려주지 않았어요',
        style: AppText.label(size: 18, color: AppColors.textTertiary),
      );
    }
    return Semantics(
      label: '배터리 $percent 퍼센트${_low ? ', 곧 갈아 주세요' : ''}',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 20,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _low ? AppColors.danger : AppColors.point,
                  width: 2,
                ),
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: (percent / 100).clamp(0.0, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: _low ? AppColors.danger : AppColors.point,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '$percent%',
              style: AppText.label(size: 18, color: AppColors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}
