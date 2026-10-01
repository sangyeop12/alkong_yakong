import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:polar/polar.dart';

double? averageValidHeartRates(Iterable<int> samples) {
  final valid = samples.where((bpm) => bpm > 0).toList();
  if (valid.isEmpty) return null;
  return valid.fold<int>(0, (sum, bpm) => sum + bpm) / valid.length;
}

double? heartRateChangePercent({
  required double? baseline,
  required double? currentAverage,
}) {
  if (baseline == null || baseline <= 0 || currentAverage == null) return null;
  return (currentAverage - baseline) / baseline * 100;
}

class PolarService {
  PolarService({Polar? polar}) : _polar = polar ?? Polar() {
    debugPrint('[POLAR_SERVICE] initialized');
    _disconnectSubscription = _polar.deviceDisconnected.listen((event) {
      // 실제 BLE 연결이 끊겼다면 이전 기능 준비 상태를 재사용하지 않는다.
      // 다음 재시도는 기존 스트림 재개에 실패한 뒤 장치를 다시 찾는다.
      _availableFeatures.remove(event.info.deviceId);
      unawaited(stopStreaming());
    });
  }

  static const String defaultDeviceId = '115F4138';

  final Polar _polar;
  final StreamController<int?> _currentBpmController =
      StreamController<int?>.broadcast();
  final StreamController<double?> _averageBpmController =
      StreamController<double?>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  final List<int> _bpmSamples = <int>[];
  final Map<String, Set<PolarSdkFeature>> _availableFeatures =
      <String, Set<PolarSdkFeature>>{};
  StreamSubscription<PolarHrData>? _hrSubscription;
  StreamSubscription<dynamic>? _disconnectSubscription;
  int _streamGeneration = 0;
  Timer? _averageTimer;
  bool _isAverageMonitoring = false;
  bool _isDisposed = false;
  bool _acceptBpmEvents = false;

  Stream<int?> get currentBpmStream => _currentBpmController.stream;
  Stream<double?> get averageBpmStream => _averageBpmController.stream;
  Stream<String> get errorStream => _errorController.stream;
  Stream<String> get deviceDisconnectedStream =>
      _polar.deviceDisconnected.map((event) => event.info.deviceId);

  /// 남은 배터리 (0~100). SDK가 연결 직후와 값이 바뀔 때 보내 준다.
  /// 우리가 물어보는 것이 아니라 기기가 알려주는 값이다.
  Stream<int> get batteryLevelStream =>
      _polar.batteryLevel.map((event) => event.level);

  Future<String> findDeviceId({
    required String targetName,
    required String targetDeviceId,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    debugPrint('[POLAR_SERVICE] search start');
    try {
      final device = await _polar
          .searchForDevice()
          .firstWhere(
            (device) =>
                device.name == targetName || device.deviceId == targetDeviceId,
          )
          .timeout(timeout);
      debugPrint('[POLAR_SERVICE] device found');
      return device.deviceId;
    } catch (error) {
      debugPrint('[POLAR_SERVICE] search failed');
      _emitError(error);
      rethrow;
    }
  }

  Future<void> connectToDevice(String deviceId) async {
    debugPrint('[POLAR_SERVICE] connect start');
    final features = <PolarSdkFeature>{};
    final hrReady = Completer<void>();
    final featureSubscription = _polar.sdkFeatureReady
        .where((event) => event.identifier == deviceId)
        .listen((event) {
          features.add(event.feature);
          if (event.feature == PolarSdkFeature.hr && !hrReady.isCompleted) {
            hrReady.complete();
          }
        });
    try {
      await _polar.connectToDevice(deviceId);
      debugPrint('[POLAR_SERVICE] connected');
      try {
        await hrReady.future.timeout(const Duration(seconds: 10));
      } catch (error) {
        debugPrint('[POLAR_SERVICE] feature check failed');
      }
      _availableFeatures[deviceId] = Set<PolarSdkFeature>.of(features);
      debugPrint('[POLAR_SERVICE] available features: $features');
      if (features.contains(PolarSdkFeature.hr)) {
        debugPrint('[POLAR_SERVICE] HR feature available');
      } else {
        debugPrint('[POLAR_SERVICE] HR feature NOT available');
      }
    } catch (error) {
      debugPrint('[POLAR_SERVICE] connect failed');
      _emitError(error);
      rethrow;
    } finally {
      await featureSubscription.cancel();
    }
  }

  Future<void> disconnectFromDevice(String deviceId) async {
    await stopStreaming();
    try {
      await _polar.disconnectFromDevice(deviceId);
      _availableFeatures.remove(deviceId);
      debugPrint('[POLAR_SERVICE] disconnected');
    } catch (error) {
      _emitError(error);
      rethrow;
    }
  }

  Future<void> startHrStreaming(String deviceId) async {
    final hasHrFeature =
        _availableFeatures[deviceId]?.contains(PolarSdkFeature.hr) ?? false;
    if (!hasHrFeature) {
      const error = 'HR service not available on device';
      debugPrint('[POLAR_SERVICE] HR feature NOT available');
      _emitError(error);
      throw StateError(error);
    }
    debugPrint('[POLAR_SERVICE] HR feature available');
    await stopStreaming();
    _bpmSamples.clear();
    _acceptBpmEvents = true;
    final generation = _streamGeneration;
    debugPrint('[POLAR_SERVICE] hr stream start');

    _hrSubscription = _polar
        .startHrStreaming(deviceId)
        .listen(
          (data) {
            if (generation != _streamGeneration) return;
            for (final sample in data.samples) {
              if (sample.contactStatusSupported && !sample.contactStatus) {
                if (_acceptBpmEvents) {
                  debugPrint('[POLAR_SERVICE] skin contact lost');
                  _acceptBpmEvents = false;
                  _averageTimer?.cancel();
                  _averageTimer = null;
                  _isAverageMonitoring = false;
                  _bpmSamples.clear();
                  _emitMeasurementReset();
                  _emitError(StateError('Skin contact lost'));
                }
                continue;
              }
              final bpm = sample.hr;
              if (bpm <= 0) continue;
              if (!_acceptBpmEvents) {
                continue;
              }
              if (_isAverageMonitoring) {
                _bpmSamples.add(bpm);
              }
              if (!_currentBpmController.isClosed) {
                _currentBpmController.add(bpm);
              }
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (generation != _streamGeneration) return;
            debugPrint('[POLAR_SERVICE] hr stream failed');
            _acceptBpmEvents = false;
            _averageTimer?.cancel();
            _averageTimer = null;
            _isAverageMonitoring = false;
            _bpmSamples.clear();
            _emitMeasurementReset();
            _emitError(error);
          },
          onDone: () {
            if (generation != _streamGeneration) return;
            debugPrint('[POLAR_SERVICE] hr stream stopped');
            _acceptBpmEvents = false;
            _averageTimer?.cancel();
            _averageTimer = null;
            _isAverageMonitoring = false;
            _bpmSamples.clear();
            _emitMeasurementReset();
            _emitError(StateError('HR stream ended'));
          },
          cancelOnError: false,
        );
  }

  Future<void> stopStreaming() async {
    _streamGeneration++;
    debugPrint('[POLAR_SERVICE] stopStreaming requested');
    _acceptBpmEvents = false;
    _averageTimer?.cancel();
    _averageTimer = null;
    _isAverageMonitoring = false;
    final subscription = _hrSubscription;
    _hrSubscription = null;
    await subscription?.cancel();
    _bpmSamples.clear();
    _emitMeasurementReset();
    debugPrint('[POLAR_SERVICE] stopStreaming completed');
  }

  void startAverageMonitoring() {
    if (!_acceptBpmEvents || _isDisposed) return;
    _averageTimer?.cancel();
    _bpmSamples.clear();
    _isAverageMonitoring = true;
    _averageTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _emitAverageBpm(),
    );
  }

  void stopAverageMonitoring() {
    _isAverageMonitoring = false;
    _averageTimer?.cancel();
    _averageTimer = null;
    _bpmSamples.clear();
    if (!_averageBpmController.isClosed) {
      _averageBpmController.add(null);
    }
  }

  void _emitMeasurementReset() {
    if (!_currentBpmController.isClosed) {
      _currentBpmController.add(null);
    }
    if (!_averageBpmController.isClosed) {
      _averageBpmController.add(null);
    }
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    debugPrint('[POLAR_SERVICE] dispose requested');
    _isDisposed = true;
    await _disconnectSubscription?.cancel();
    await stopStreaming();
    await Future.wait<void>(<Future<void>>[
      _currentBpmController.close(),
      _averageBpmController.close(),
      _errorController.close(),
    ]);
    debugPrint('[POLAR_SERVICE] dispose completed');
  }

  void _emitAverageBpm() {
    if (!_acceptBpmEvents || !_isAverageMonitoring) return;
    final average = averageValidHeartRates(_bpmSamples);
    _bpmSamples.clear();
    if (average != null && !_averageBpmController.isClosed) {
      _averageBpmController.add(average);
    }
  }

  void _emitError(Object error) {
    if (!_errorController.isClosed) {
      _errorController.add('sensor_error');
    }
  }
}
