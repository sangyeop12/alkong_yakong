import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/session/mvp_session.dart';
import '../../../biosignal/data/biosignal_dataset_collector.dart';
import '../../../biosignal/data/polar_service.dart';

/// 실시간 심박 모니터링 화면 (흐르는 애니메이션 버전).
/// 보호자 현황 탭의 "현재 심박" 카드를 누르면 진입.
///
/// PolarService의 HR 스트림으로 현재 심박과 그래프를 갱신한다.
///
/// 부담 최소화: 최근 _maxPoints 개만 메모리에 유지하고, 화면을 벗어나면
/// dispose()에서 스트림·애니메이션을 정리해 배터리/리소스 낭비를 막는다.
/// 위치: lib/features/dashboard/presentation/screens/biosignal_live_screen.dart
class BiosignalLiveScreen extends StatefulWidget {
  final Color accent;
  final String? patientName; // 보호자가 볼 때 환자 이름. 환자 본인은 null.

  // 예전의 `baseHr = 76`(환자별 평상시 심박)은 어디에도 쓰이지 않는 가짜
  // 기본값이라 지웠다. 평소 심박은 화면의 "평소 심박 측정"으로만 잰다.
  const BiosignalLiveScreen({
    super.key,
    this.accent = kGuardian,
    this.patientName,
  });

  @override
  State<BiosignalLiveScreen> createState() => _BiosignalLiveScreenState();
}

class _BiosignalLiveScreenState extends State<BiosignalLiveScreen>
    with SingleTickerProviderStateMixin {
  static const int _maxPoints = 60; // 그래프에 유지할 최근 심박 개수
  static const Duration _interval = Duration(seconds: 1); // 새 값 주기
  static const Color _danger = AppColors.legacyRed;
  static const String _targetDeviceId = '115F4138';
  static const String _targetDeviceName = 'Polar Sense 115F4138';

  // ── Polar 실측 상태 ──
  int? _currentHr;
  double? _usualHrBpm;
  bool _isUsualHrMeasuring = false;
  int _usualHrRemainingSeconds = 0;
  bool _isAnomalyDetected = false;
  bool _isConnected = false;
  bool _isStreaming = false;
  String? _connectionError;
  String? _activeDeviceId;
  bool _isDisposed = false;
  bool _hasAttemptedReconnect = false;
  // ignore: unused_field  (연동 시 사용: AI 분석 중 표시)
  final bool _isAnalyzing = false;
  // ignore: unused_field  (연동 시 사용: AI 분석 리포트)
  final String _aiReport = '';

  // 흐름 구현용 실측값 리스트
  final List<double> _hr = [];
  final List<int> _usualHrSamples = [];
  Timer? _usualHrTimer;
  late final AnimationController _anim; // 매 프레임 다시 그리기 + 흐름 진행도(0~1)
  final PolarService _polarService = PolarService();
  final BiosignalDatasetCollector _datasetCollector =
      BiosignalDatasetCollector();
  final ApiClient _apiClient = ApiClient();
  StreamSubscription<int?>? _currentBpmSub;
  StreamSubscription<double?>? _averageBpmSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<String>? _deviceDisconnectedSub;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: _interval);
    _subscribeToPolarStreams();
    unawaited(_connectAndStartStreaming());
  }

  @override
  void dispose() {
    debugPrint('[POLAR_UI] dispose called');
    _isDisposed = true;
    _usualHrTimer?.cancel();
    unawaited(_disposePolarResources());
    _anim.dispose(); // 애니메이션 정리 (배터리/리소스 절약)
    super.dispose();
  }

  Future<void> _disposePolarResources() async {
    await _currentBpmSub?.cancel();
    await _averageBpmSub?.cancel();
    await _errorSub?.cancel();
    await _deviceDisconnectedSub?.cancel();
    _currentBpmSub = null;
    _averageBpmSub = null;
    _errorSub = null;
    _deviceDisconnectedSub = null;
    debugPrint('[POLAR_UI] stream subscriptions cancelled');
    await _shutdownPolar();
    debugPrint('[POLAR_UI] dispose cleanup completed');
  }

  void _subscribeToPolarStreams() {
    _currentBpmSub = _polarService.currentBpmStream.listen(_handleCurrentBpm);
    _averageBpmSub = _polarService.averageBpmStream.listen((average) {
      if (average != null) {
        unawaited(_sendAverageBpm(average));
      }
    });
    _errorSub = _polarService.errorStream.listen(_handlePolarError);
    _deviceDisconnectedSub = _polarService.deviceDisconnectedStream.listen(
      _handleDeviceDisconnected,
    );
  }

  Future<void> _connectAndStartStreaming() async {
    debugPrint('[POLAR_UI] connect requested');
    try {
      final permissionLabels = <Permission, String>{
        Permission.bluetoothScan: '블루투스 검색',
        Permission.bluetoothConnect: '블루투스 연결',
        Permission.locationWhenInUse: '위치',
      };
      debugPrint('[POLAR_UI] requesting permissions');
      final permissionStatuses = await permissionLabels.keys.toList().request();
      debugPrint(
        '[POLAR_UI] permission results: ${permissionStatuses.entries.map((entry) => '${permissionLabels[entry.key]}=${entry.value.name}').join(', ')}',
      );

      final rejectedPermissions = permissionStatuses.entries
          .where((entry) => !entry.value.isGranted)
          .map(
            (entry) =>
                '${permissionLabels[entry.key]}(${entry.value.isPermanentlyDenied ? '영구 거부' : '거부'})',
          )
          .toList();
      if (rejectedPermissions.isNotEmpty) {
        debugPrint('[POLAR_UI] permission denied');
        _handlePolarError('권한 거부: ${rejectedPermissions.join(', ')}');
        return;
      }

      debugPrint('[POLAR_UI] searching for Polar device');
      final deviceId = await _polarService.findDeviceId(
        targetName: _targetDeviceName,
        targetDeviceId: _targetDeviceId,
      );
      _activeDeviceId = deviceId;

      debugPrint('[POLAR_UI] connectToDevice($deviceId)');
      await _polarService.connectToDevice(deviceId);
      debugPrint('[POLAR_UI] connect success');
      if (_isDisposed) {
        await _polarService.disconnectFromDevice(deviceId);
        return;
      }
      if (mounted) {
        setState(() {
          _isConnected = true;
          _connectionError = null;
        });
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      if (_isDisposed) return;
      debugPrint('[POLAR_UI] startHrStreaming($deviceId)');
      await _polarService.startHrStreaming(deviceId);
      debugPrint('[POLAR_UI] stream started');
    } catch (error) {
      _handlePolarError(error.toString());
    }
  }

  void _handleDeviceDisconnected(String deviceId) {
    debugPrint('[POLAR_UI] device disconnected: $deviceId');
    if (_isDisposed || deviceId != _activeDeviceId) return;
    if (mounted) {
      setState(() {
        _isConnected = false;
        _isStreaming = false;
        _connectionError = 'Polar 기기 연결이 끊어졌습니다.';
      });
    }
    _startReconnectOnce();
  }

  void _startReconnectOnce() {
    if (_hasAttemptedReconnect) {
      debugPrint('[POLAR_UI] reconnect already attempted');
      return;
    }
    _hasAttemptedReconnect = true;
    unawaited(_reconnectOnce());
  }

  Future<void> _reconnectOnce() async {
    try {
      debugPrint('[POLAR_UI] retry start');
      await _polarService.stopStreaming();
      final previousDeviceId = _activeDeviceId;
      if (previousDeviceId != null) {
        try {
          await _polarService.disconnectFromDevice(previousDeviceId);
        } catch (error) {
          debugPrint('[POLAR_UI] retry disconnect ignored: $error');
        }
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      if (_isDisposed) return;

      final deviceId = await _polarService.findDeviceId(
        targetName: _targetDeviceName,
        targetDeviceId: _targetDeviceId,
      );
      debugPrint('[POLAR_UI] retry search success: $deviceId');
      if (_isDisposed) return;
      _activeDeviceId = deviceId;

      await _polarService.connectToDevice(deviceId);
      debugPrint('[POLAR_UI] retry connect success');
      if (_isDisposed) {
        await _polarService.disconnectFromDevice(deviceId);
        return;
      }
      if (mounted) {
        setState(() {
          _isConnected = true;
          _connectionError = null;
        });
      }

      await Future<void>.delayed(const Duration(seconds: 2));
      if (_isDisposed) return;
      await _polarService.startHrStreaming(deviceId);
      debugPrint('[POLAR_UI] retry stream start');
    } catch (error) {
      debugPrint('[POLAR_UI] retry failed: $error');
      _handlePolarError(error.toString());
    }
  }

  void _handleCurrentBpm(int? bpm) {
    if (!mounted || _isDisposed) return;
    if (bpm == null) {
      _datasetCollector.clearSignalWindow();
      _usualHrTimer?.cancel();
      setState(() {
        _currentHr = null;
        _isUsualHrMeasuring = false;
        _usualHrRemainingSeconds = 0;
        _usualHrSamples.clear();
        _isStreaming = false;
        _isAnomalyDetected = false;
        _hr.clear();
      });
      _anim
        ..stop()
        ..reset();
      debugPrint('[POLAR_UI] bpm cleared');
      return;
    }
    debugPrint('[POLAR_UI] bpm received: $bpm');
    _datasetCollector.addPolarBpm(
      bpm,
      deviceId: _activeDeviceId ?? _targetDeviceId,
    );
    setState(() {
      if (_hr.isEmpty) {
        _hr.addAll(List<double>.filled(2, bpm.toDouble()));
      }
      _hr.add(bpm.toDouble());
      if (_hr.length > _maxPoints + 1) _hr.removeAt(0);
      _currentHr = bpm;
      _isConnected = true;
      _isStreaming = true;
      _connectionError = null;
      _isAnomalyDetected = bpm > 100;
      if (_isUsualHrMeasuring) {
        _usualHrSamples.add(bpm);
      }
    });
    _anim.forward(from: 0);
  }

  void _startUsualHrMeasurement() {
    if (_isUsualHrMeasuring || _currentHr == null) return;
    _usualHrTimer?.cancel();
    setState(() {
      _isUsualHrMeasuring = true;
      _usualHrRemainingSeconds = 15;
      _usualHrSamples
        ..clear()
        ..add(_currentHr!);
    });

    _usualHrTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _isDisposed) {
        timer.cancel();
        return;
      }

      if (_usualHrRemainingSeconds <= 1) {
        timer.cancel();
        _completeUsualHrMeasurement();
        return;
      }

      setState(() {
        _usualHrRemainingSeconds--;
      });
    });
  }

  void _completeUsualHrMeasurement() {
    if (_usualHrSamples.isEmpty) {
      setState(() {
        _isUsualHrMeasuring = false;
        _usualHrRemainingSeconds = 0;
        _usualHrBpm = null;
      });
      return;
    }

    final total = _usualHrSamples.fold<int>(0, (sum, bpm) => sum + bpm);
    setState(() {
      _usualHrBpm = total / _usualHrSamples.length;
      _isUsualHrMeasuring = false;
      _usualHrRemainingSeconds = 0;
    });
  }

  String get _usualHrValueText =>
      _usualHrBpm == null ? '--' : _usualHrBpm!.round().toString();

  String get _hrChangeText {
    final currentHr = _currentHr;
    final usualHr = _usualHrBpm;
    if (currentHr == null || usualHr == null || usualHr <= 0) {
      return '--';
    }
    final changeRate = (currentHr - usualHr) / usualHr * 100;
    final sign = changeRate > 0 ? '+' : '';
    return '$sign${changeRate.toStringAsFixed(1)}';
  }

  void _handlePolarError(String error) {
    debugPrint('[POLAR_UI] error: $error');
    if (!mounted || _isDisposed) return;
    setState(() {
      _connectionError = error;
      _isConnected = false;
      _isStreaming = false;
    });
    if (error.contains('PolarDeviceDisconnected')) {
      _startReconnectOnce();
    }
  }

  Future<void> _sendAverageBpm(double average) async {
    final userId = MvpSession.userId.trim();
    if (userId.isEmpty) {
      debugPrint('Skipping average BPM upload: user ID is empty.');
      return;
    }
    debugPrint('[POLAR_UI] sending 30s avg: $average');
    try {
      await _apiClient.post(
        '/api/v1/biosignal/heart-rate',
        body: {
          'user_id': userId,
          'bpm': average.round(),
          'device_id': _activeDeviceId ?? _targetDeviceId,
          'source': 'POLAR_30S_AVERAGE',
        },
      );
      debugPrint('[POLAR_UI] avg upload success');
    } on ApiException catch (error) {
      debugPrint('[POLAR_UI] avg upload failed: $error');
    } catch (error) {
      debugPrint('[POLAR_UI] avg upload failed: $error');
    }
  }

  Future<void> _shutdownPolar() async {
    try {
      await _polarService.stopStreaming();
      final deviceId = _activeDeviceId;
      if (deviceId != null) {
        await _polarService.disconnectFromDevice(deviceId);
      }
    } catch (error) {
      debugPrint('Unable to disconnect Polar device: $error');
    } finally {
      await _polarService.dispose();
    }
  }

  bool get _normal => !_isAnomalyDetected;

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    final Color hrColor = _isAnomalyDetected ? _danger : accent;

    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          '실시간 심박',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          children: [
            // ── 현재 심박 큰 숫자 ──
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 26),
              decoration: BoxDecoration(
                color: hrColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: hrColor.withValues(alpha: 0.20)),
              ),
              child: Column(
                children: [
                  Text(
                    widget.patientName == null
                        ? '지금'
                        : '${widget.patientName}님 · 지금',
                    style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 8),
                  // 글자를 키우면 큰 숫자가 카드를 넘는다. 한 줄을 통째로
                  // 줄여서 잘리지 않게 한다.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.favorite_rounded,
                          size: 30,
                          color: kPrimary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _isStreaming && _currentHr != null
                              ? '$_currentHr'
                              : '--',
                          style: TextStyle(
                            fontSize: 56,
                            fontWeight: FontWeight.w700,
                            color: hrColor,
                            height: 1,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'bpm',
                          style: TextStyle(
                            fontSize: 18,
                            color: Colors.grey[500],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  _statusChip(),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── 흐르는 실시간 그래프 ──
            Row(
              children: [
                const Flexible(
                  child: Text(
                    '실시간 추이',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: kText,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _LiveDot(color: _normal ? accent : _danger),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: _card(),
              child: SizedBox(
                height: 190,
                child: AnimatedBuilder(
                  animation: _anim,
                  builder: (context, _) {
                    return CustomPaint(
                      size: Size.infinite,
                      painter: _FlowPainter(
                        values: _hr,
                        progress: _anim.value, // 0~1, 한 칸 흐름 진행도
                        lineColor: hrColor,
                        minY: 50,
                        maxY: 150,
                        bandLow: 60,
                        bandHigh: 100,
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 10),
            Center(child: _legend(AppColors.legacyMint, '정상 범위 (60~100)')),
            const SizedBox(height: 18),

            // ── 보조 지표 ──
            Row(
              children: [
                _metric('평소 심박', _usualHrValueText, 'bpm', accent),
                const SizedBox(width: 12),
                _metric('심박 변화', _hrChangeText, '%', accent),
              ],
            ),
            const SizedBox(height: 12),
            _usualHrButton(accent),
            const SizedBox(height: 18),

            if (_isAnomalyDetected) _anomalyCard(),
          ],
        ),
      ),
    );
  }

  Widget _statusChip() {
    final hasError = _connectionError != null;
    final Color c = hasError || _isAnomalyDetected
        ? _danger
        : AppColors.legacyGreen;
    final String label = _isAnomalyDetected && _isStreaming
        ? '심박 이상 감지'
        : _sensorStatusLabel;
    final IconData icon = hasError || _isAnomalyDetected
        ? Icons.warning_amber_rounded
        : Icons.check_circle;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: c),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: c,
            ),
          ),
        ],
      ),
    );
  }

  String get _sensorStatusLabel {
    if (_connectionError != null) return '연결 오류';
    if (!_isConnected) return '연결 대기';
    if (!_isStreaming) return '연결됨';
    return '실시간 측정';
  }

  Widget _anomalyCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _danger.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.warning_amber_rounded, color: _danger, size: 20),
              SizedBox(width: 8),
              Text(
                '심박 이상 감지',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: kText,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '안정 상태에서 심박이 분당 100회를 넘었어요. '
            '잠시 지켜보고, 계속되면 환자에게 연락해보세요.',
            style: TextStyle(
              fontSize: 13.5,
              color: Colors.grey[700],
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _usualHrButton(Color color) {
    final isEnabled =
        _isStreaming && _currentHr != null && !_isUsualHrMeasuring;
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: isEnabled ? _startUsualHrMeasurement : null,
        icon: const Icon(Icons.monitor_heart_rounded, size: 18),
        label: Text(
          _isUsualHrMeasuring
              ? '15초 측정 중... $_usualHrRemainingSeconds초'
              : '평소 심박 측정',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color.withValues(alpha: 0.45)),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }

  Widget _metric(String label, String value, String unit, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: _card(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                  if (unit.isNotEmpty) ...[
                    const SizedBox(width: 3),
                    Text(
                      unit,
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _legend(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 11.5, color: Colors.grey[600])),
      ],
    );
  }
}

/// 라인을 한 칸씩 왼쪽으로 흐르게 그리는 페인터.
/// progress(0~1)만큼 왼쪽으로 이동시켜 새 값이 오른쪽에서 부드럽게 들어온다.
class _FlowPainter extends CustomPainter {
  final List<double> values;
  final double progress;
  final Color lineColor;
  final double minY, maxY, bandLow, bandHigh;

  _FlowPainter({
    required this.values,
    required this.progress,
    required this.lineColor,
    required this.minY,
    required this.maxY,
    required this.bandLow,
    required this.bandHigh,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final w = size.width;
    final h = size.height;

    // 화면에 보이는 점 개수 (마지막 한 칸은 흐름으로 들어오는 중)
    final int visible = values.length - 1;
    final double step = w / (visible - 1);

    double yFor(double v) =>
        h - ((v - minY) / (maxY - minY)).clamp(0.0, 1.0) * h;
    // i번째 점의 x. progress만큼 왼쪽으로 당겨 흐르게.
    double xFor(int i) => (i - progress) * step;

    // 정상 범위 밴드
    final band = Paint()..color = AppColors.legacyMint;
    canvas.drawRect(Rect.fromLTRB(0, yFor(bandHigh), w, yFor(bandLow)), band);

    // 가로 보조선
    final grid = Paint()
      ..color = AppColors.legacyLine
      ..strokeWidth = 1;
    for (final v in [75.0, 100.0, 125.0]) {
      final y = yFor(v);
      canvas.drawLine(Offset(0, y), Offset(w, y), grid);
    }

    // 라인 path (오른쪽 끝은 다음 값으로 보간되어 들어옴)
    final path = Path();
    for (int i = 0; i < values.length; i++) {
      final x = xFor(i);
      final y = yFor(values[i]);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    // 라인 아래 채움
    final lastX = xFor(values.length - 1);
    final fill = Path.from(path)
      ..lineTo(lastX, h)
      ..lineTo(xFor(0), h)
      ..close();
    canvas.drawPath(fill, Paint()..color = lineColor.withValues(alpha: 0.10));

    // 라인
    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );

    // 현재 지점 점 (오른쪽 가장자리 근처, 직전 값 위치)
    final cx = xFor(values.length - 2);
    final cy = yFor(values[values.length - 2]);
    if (cx <= w + 4) {
      canvas.drawCircle(Offset(cx, cy), 4.5, Paint()..color = lineColor);
      canvas.drawCircle(
        Offset(cx, cy),
        4.5,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FlowPainter old) =>
      old.progress != progress ||
      old.values != values ||
      old.lineColor != lineColor;
}

BoxDecoration _card() => BoxDecoration(
  color: kCard,
  borderRadius: BorderRadius.circular(18),
  boxShadow: [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.04),
      blurRadius: 12,
      offset: const Offset(0, 4),
    ),
  ],
);

/// 깜빡이는 라이브 표시 점
class _LiveDot extends StatefulWidget {
  final Color color;
  const _LiveDot({required this.color});

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.3, end: 1.0).animate(_c),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            'LIVE',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: widget.color,
            ),
          ),
        ],
      ),
    );
  }
}
