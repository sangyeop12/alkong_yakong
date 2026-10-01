import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_feedback.dart';
import '../../../../core/widgets/recovery_view.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../medication/domain/medication_models.dart';
import '../../application/heart_sensor.dart';
import '../../domain/heart_data.dart';
import 'saved_screen.dart';

/// 27 / 28 · 심박수 재는 중 → 측정이 끝났어요.
///
/// 센서의 15초 준비와 별도 30초 측정, 저장 응답에 따라 진행한다.
class MeasureScreen extends StatefulWidget {
  final String guardianTitle;

  /// 밖에서 넣어 주는 센서. 없으면 이 화면이 하나 만들어 쓴다.
  final HeartSensor? sensor;
  final HeartMeasurementContext measurementContext;
  final bool returnToPreviousScreen;
  final Future<void> Function()? onSaved;

  const MeasureScreen({
    super.key,
    this.guardianTitle = '',
    this.sensor,
    this.measurementContext = HeartMeasurementContext.general,
    this.returnToPreviousScreen = false,
    this.onSaved,
  });

  @override
  State<MeasureScreen> createState() => _MeasureScreenState();
}

/// GoRouter가 관리하는 심박 측정 경로에 전달하는 내부 화면 인자.
///
/// 공개 API나 저장 계약이 아니라 기존 HeartScreen 인스턴스의 센서와
/// 사용자가 고른 측정 목적을 다음 화면에 그대로 넘기기 위한 값이다.
class HeartMeasureRouteArgs {
  final String guardianTitle;
  final HeartSensor? sensor;
  final HeartMeasurementContext measurementContext;
  final Future<void> Function()? onSaved;

  const HeartMeasureRouteArgs({
    required this.guardianTitle,
    required this.sensor,
    required this.measurementContext,
    this.onSaved,
  });
}

class _MeasureScreenState extends State<MeasureScreen> {
  static const int _totalSeconds = 45;

  /// 센서를 이 화면이 만들었으면 이 화면이 치운다.
  late final bool _ownsSensor = widget.sensor == null;
  late final HeartSensor _sensor = widget.sensor ?? HeartSensor();

  bool _openingSaved = false;
  int get _elapsed => _sensor.elapsedSeconds;

  int get _progress => (_elapsed * 100 / _totalSeconds).round().clamp(0, 100);

  bool get _done => _sensor.saveStatus == HeartSaveStatus.saved;
  bool get _saveFailed =>
      _sensor.saveStatus == HeartSaveStatus.failed ||
      _sensor.saveStatus == HeartSaveStatus.unknown;

  /// 화면에 띄울 값. 센서가 아직 아무것도 못 줬으면 null — 숫자를 채우지 않는다.
  int? get _value => _done ? _sensor.savedBpm : _sensor.bpm;

  bool get _live => _sensor.status == HeartSensorStatus.streaming;

  /// 센서가 끊겼거나 붙지 못한 상태.
  bool get _lost =>
      _sensor.status == HeartSensorStatus.disconnected ||
      _sensor.status == HeartSensorStatus.failed;

  Future<void> _leaveMeasurement() async {
    final router = widget.returnToPreviousScreen
        ? GoRouter.maybeOf(context)
        : null;
    if (router != null) {
      router.go('/biosignal');
      return;
    }
    await Navigator.of(context).maybePop();
  }

  @override
  void initState() {
    super.initState();
    _sensor.addListener(_onSensor);
    if (_ownsSensor) {
      unawaited(_sensor.start(measurementContext: widget.measurementContext));
    } else {
      _sensor.beginMeasurement(measurementContext: widget.measurementContext);
    }
  }

  /// 처음부터 다시 잰다. 센서가 붙어 있지 않으면 다시 붙인다.
  void _restart() {
    if (_live) {
      _sensor.beginMeasurement(measurementContext: widget.measurementContext);
    } else {
      unawaited(_sensor.start(measurementContext: widget.measurementContext));
    }
  }

  void _onSensor() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _sensor.removeListener(_onSensor);
    _sensor.endMeasurement();
    // 보이지도 않는 화면이 센서를 잡고 있지 않도록.
    if (_ownsSensor) _sensor.dispose();
    super.dispose();
  }

  /// 남은 시간.
  int get _secondsLeft => (_totalSeconds - _elapsed).clamp(0, _totalSeconds);

  /// 5e 회복 화면 — 오류가 아니라 "지금 못 재고 있다"로 말한다.
  ///
  /// 한 번도 못 잰 채로 센서가 안 붙으면 진행 막대를 계속 채워 봐야
  /// 아무 값도 나오지 않는다. 그 자리에서 다시 붙는 방법을 알려준다.
  Widget _recovery() {
    return RecoveryView(
      title: '지금은 심장 박동을\n재지 못하고 있어요',
      reassurance: '센서의 심박 신호를 확인하지 못했어요. ',
      reassuranceEmphasis: '센서 연결을 확인해 주세요.',
      steps: const [
        '센서가 팔이나 가슴에 잘 붙어 있는지 만져보세요',
        '센서 가운데 단추를 한 번 누르세요',
        '전화기를 센서 가까이 두세요',
      ],
      actionLabel: '다시 연결하기',
      onAction: _restart,
      stillWorksTitle: '약 알림은 그대로 와요',
      stillWorksBody: '센서가 끊겨도 복약 알림에는 영향이 없어요.',
      helperText: '자동 연락은 지원하지 않아요',
      // 어르신 화면에서 밖으로 전화를 걸지 않는다.
      onCallHelper: () => showSeniorSnackbar(context, '필요하면 보호자에게 직접 연락해 주세요.'),
      footnote: _sensor.lastReadAt == null
          ? null
          : '마지막으로 잰 시각 · 오늘 '
                '${DoseSlot.absoluteTime(_sensor.lastReadAt!)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final value = _value;

    // 한 번도 못 잰 채로 센서가 안 붙었으면 재는 시늉을 하지 않는다.
    if (_lost &&
        !_done &&
        !_saveFailed &&
        _sensor.saveStatus != HeartSaveStatus.saving) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: Column(
          children: [
            SeniorBackHeader(title: '심박수 관리', onBack: _leaveMeasurement),
            Expanded(child: _recovery()),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          SeniorBackHeader(
            title: _done ? '측정이 끝났어요' : '심박수 측정 중',
            onBack: _leaveMeasurement,
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _MeasureCard(
                    progress: _progress,
                    // 재는 동안에도 센서가 주는 값을 그대로 보여 준다.
                    // 다 될 때까지 "–"만 보이면 되고 있는지 알 수 없다.
                    value: value,
                    done: _done,
                    statusText: _done
                        ? '저장되었어요'
                        : _saveFailed
                        ? '저장 상태를 확인해 주세요'
                        : _sensor.saveStatus == HeartSaveStatus.saving
                        ? '저장 확인 중이에요'
                        : !_sensor.measuring
                        ? '심박 신호를 기다려요'
                        : '측정 중이에요 · 움직이지 마세요',
                  ),
                  const SizedBox(height: 12),
                  if (!_done && !_saveFailed) ...[
                    SeniorCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 18,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '측정하는 동안 이렇게 해주세요',
                            style: AppText.cardTitle(size: 20),
                          ),
                          const SizedBox(height: 14),
                          const NumberedSteps(
                            boxed: false,
                            steps: [
                              '앉아서 가만히 계세요',
                              '숨을 편하게 쉬세요',
                              '심박 센서는 그대로 두세요',
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    SeniorCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 17,
                      ),
                      child: LabelValueRow(
                        label: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              margin: const EdgeInsets.only(top: 8),
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: _lost
                                    ? AppColors.danger
                                    : AppColors.point,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                _lost
                                    ? '센서가 떨어졌어요'
                                    : _live
                                    ? '폴라 센서로 재고 있어요'
                                    : '폴라 센서를 찾고 있어요',
                                style: AppText.cardTitle(
                                  size: 19,
                                  color: _lost
                                      ? AppColors.danger
                                      : AppColors.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                        value: Text(
                          _sensor.saveStatus == HeartSaveStatus.saving
                              ? '저장 확인 중이에요'
                              : !_sensor.measuring
                              ? '심박 신호를 기다려요'
                              : '약 $_secondsLeft초 남았어요',
                          style: AppText.caption(size: 17.5),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SeniorButton(
                      label: '그만두기',
                      kind: SeniorButtonKind.secondary,
                      minHeight: 66,
                      fontSize: 21,
                      onPressed: _leaveMeasurement,
                    ),
                  ] else if (_saveFailed) ...[
                    _NoValueCard(
                      unknown: _sensor.saveStatus == HeartSaveStatus.unknown,
                    ),
                    const SizedBox(height: 16),
                    SeniorButton(
                      label: '다시 측정',
                      icon: TablerIcons.refresh,
                      minHeight: 70,
                      fontSize: 23,
                      onPressed: _restart,
                    ),
                    const SizedBox(height: 12),
                    SeniorButton(
                      label: '그만두기',
                      kind: SeniorButtonKind.secondary,
                      minHeight: 66,
                      fontSize: 21,
                      onPressed: _leaveMeasurement,
                    ),
                  ] else ...[
                    _ResultCard(
                      lowest: _sensor.lowest,
                      highest: _sensor.highest,
                    ),
                    const SizedBox(height: 16),
                    SeniorButton(
                      label: '저장된 기록 확인하기',
                      minHeight: 74,
                      fontSize: 24,
                      elevated: true,
                      onPressed: () async {
                        if (_openingSaved ||
                            !_done ||
                            _sensor.savedBpm == null) {
                          return;
                        }
                        _openingSaved = true;
                        final savedBpm = _sensor.savedBpm!;
                        final savedAt = _sensor.savedAt;
                        final route = MaterialPageRoute<bool>(
                          builder: (_) => SavedScreen(
                            bpm: savedBpm,
                            savedAt: savedAt,
                            measurementContext: _sensor.savedMeasurementContext,
                            guardianTitle: widget.guardianTitle,
                            returnToPreviousScreen:
                                widget.returnToPreviousScreen,
                          ),
                        );
                        final router = widget.returnToPreviousScreen
                            ? GoRouter.maybeOf(context)
                            : null;
                        if (router != null) {
                          router.go(
                            '/biosignal/saved',
                            extra: HeartSavedRouteArgs(
                              bpm: savedBpm,
                              savedAt: savedAt,
                              measurementContext:
                                  _sensor.savedMeasurementContext,
                              guardianTitle: widget.guardianTitle,
                              onSaved: widget.onSaved,
                            ),
                          );
                          return;
                        }
                        if (widget.returnToPreviousScreen) {
                          final confirmed = await Navigator.of(
                            context,
                          ).push<bool>(route);
                          if (!context.mounted) return;
                          if (confirmed == true) {
                            Navigator.of(context).pop(true);
                          } else {
                            setState(() => _openingSaved = false);
                          }
                          return;
                        }
                        Navigator.of(context).pushReplacement(route);
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
}

/// 큰 원 + 진행 막대.
class _MeasureCard extends StatelessWidget {
  final int progress;
  final int? value;
  final bool done;
  final String statusText;

  const _MeasureCard({
    required this.progress,
    required this.value,
    required this.done,
    required this.statusText,
  });

  @override
  Widget build(BuildContext context) {
    return SeniorCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      child: Column(
        children: [
          _PulsingHeart(active: !done),
          const SizedBox(height: 18),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 8,
            children: [
              Text(value?.toString() ?? '–', style: AppText.hero(size: 64)),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '회 / 분',
                  style: AppText.label(size: 21, color: AppColors.textTertiary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 12,
              child: LinearProgressIndicator(
                value: progress / 100,
                backgroundColor: AppColors.bg,
                valueColor: const AlwaysStoppedAnimation(AppColors.point),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            statusText,
            textAlign: TextAlign.center,
            style: AppText.cardTitle(size: 20, color: AppColors.point),
          ),
        ],
      ),
    );
  }
}

/// 1분이 지나도 값이 하나도 없을 때. 결과 칸 대신 다시 해 볼 방법을 둔다.
class _NoValueCard extends StatelessWidget {
  final bool unknown;
  const _NoValueCard({required this.unknown});

  @override
  Widget build(BuildContext context) {
    return SeniorCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            unknown ? '저장 여부를 확인하지 못했어요' : '기록을 저장하지 못했어요',
            style: AppText.cardTitle(size: 20),
          ),
          const SizedBox(height: 14),
          NumberedSteps(
            boxed: false,
            steps: [
              '인터넷 연결을 확인해 주세요',
              if (unknown) '서버에는 이미 저장되었을 수 있어요',
              '다시 재기는 새 측정을 시작해요',
            ],
          ),
        ],
      ),
    );
  }
}

/// 132×132 원 안의 심장. 재는 동안만 천천히 뛴다.
class _PulsingHeart extends StatefulWidget {
  final bool active;
  const _PulsingHeart({required this.active});

  @override
  State<_PulsingHeart> createState() => _PulsingHeartState();
}

class _PulsingHeartState extends State<_PulsingHeart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_PulsingHeart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: 132,
        height: 132,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: AppColors.pointTint,
          shape: BoxShape.circle,
        ),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            // 0% 크게·선명 → 50% 작게·흐리게. 시니어 화면이라 느리게 둔다.
            final t = Curves.easeInOut.transform(_controller.value);
            return Opacity(
              opacity: 1 - 0.65 * t,
              child: Transform.scale(scale: 1 - 0.28 * t, child: child),
            );
          },
          child: const Icon(
            TablerIcons.heartbeat,
            size: 64,
            color: AppColors.point,
          ),
        ),
      ),
    );
  }
}

/// 1분 동안 잰 결과 — 가장 낮게 / 가장 높게.
class _ResultCard extends StatelessWidget {
  /// 실제 표본이 없으면 평균을 최저·최고로 대신 표시하지 않는다.
  final int? lowest;
  final int? highest;

  const _ResultCard({required this.lowest, required this.highest});

  @override
  Widget build(BuildContext context) {
    return SeniorCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('측정한 결과', style: AppText.cardTitle()),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _MinMaxBox(label: '가장 낮게', value: lowest),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MinMaxBox(label: '가장 높게', value: highest),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('준비 시간을 포함해 받은 심박수의 범위예요.', style: AppText.body(size: 18)),
        ],
      ),
    );
  }
}

class _MinMaxBox extends StatelessWidget {
  final String label;
  final int? value;

  const _MinMaxBox({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.sunken,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: AppText.label(size: 17.5)),
          const SizedBox(height: 4),
          Text(value?.toString() ?? '–', style: AppText.cardTitle(size: 26)),
        ],
      ),
    );
  }
}
