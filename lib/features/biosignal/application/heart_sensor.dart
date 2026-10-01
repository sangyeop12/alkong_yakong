import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/network/api_client.dart';
import '../../../core/session/mvp_session.dart';
import '../data/biosignal_dataset_collector.dart';
import '../data/polar_service.dart';
import '../domain/heart_data.dart';

/// 센서가 지금 어떤 상태인지.
///
/// 화면은 이 다섯 가지만 보고 그린다. 붙는 중인지 끊긴 것인지를
/// 화면마다 따로 판단하면 같은 상황을 서로 다르게 말하게 된다.
enum HeartSensorStatus { idle, connecting, streaming, disconnected, failed }

enum HeartSaveStatus { idle, saving, saved, failed, unknown }

/// 폴라 센서 한 대와 잇는 일을 모아 둔 자리.
///
/// **화면은 상태만 읽는다.** 연결·구독·업로드는 전부 여기서만 일어난다.
/// 화면마다 배선을 따로 두면 한쪽만 고쳐지고 다른 쪽이 남는다.
///
/// 두 갈래를 섞지 않는다.
/// - 운영: 30초 평균을 `/api/v1/biosignal/heart-rate` 로 올린다.
/// - 데이터셋: 매 초 값을 [BiosignalDatasetCollector] 로 따로 모은다.
class HeartSensor extends ChangeNotifier {
  HeartSensor({
    PolarService? polar,
    ApiClient? apiClient,
    BiosignalDatasetCollector? datasetCollector,
    Future<bool> Function()? requestPermissions,
  }) : _polar = polar ?? PolarService(),
       _apiClient = apiClient ?? ApiClient(),
       _datasetCollector = datasetCollector ?? BiosignalDatasetCollector(),
       _requestPermissions = requestPermissions ?? _requestSensorPermissions {
    _subscribeToPolarStreams();
  }

  /// 최근 값 몇 개까지 들고 있을지. 가장 낮게·가장 높게를 여기서 낸다.
  static const int _sampleWindow = 60;

  final PolarService _polar;
  final ApiClient _apiClient;
  final BiosignalDatasetCollector _datasetCollector;
  final Future<bool> Function() _requestPermissions;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final List<int> _samples = <int>[];
  final List<int> _baselineSamples = <int>[];

  HeartSensorStatus _status = HeartSensorStatus.idle;
  int? _bpm;
  int? _battery;
  String? _deviceId;
  DateTime? _lastReadAt;
  double? _baselineBpm;
  double? _currentAverageBpm;
  Timer? _baselineTimer;
  bool _isBaselineMeasuring = false;
  bool _connecting = false;
  bool _disposed = false;
  int _session = 0;
  bool _acceptSamples = false;
  bool _measurementActive = true;
  Timer? _progressTimer;
  Timer? _signalTimer;
  // Transport silence tolerance, not a medical BPM threshold.
  static const Duration _signalTimeout = Duration(seconds: 10);
  int _elapsedSeconds = 0;
  HeartSaveStatus _saveStatus = HeartSaveStatus.idle;
  int? _savedBpm;
  DateTime? _savedAt;
  HeartMeasurementContext _measurementContext = HeartMeasurementContext.general;
  HeartMeasurementContext _savedMeasurementContext =
      HeartMeasurementContext.general;
  double? _changePercent;

  HeartSaveStatus get saveStatus => _saveStatus;
  int? get savedBpm => _savedBpm;
  DateTime? get savedAt => _savedAt;
  HeartMeasurementContext get measurementContext => _measurementContext;
  HeartMeasurementContext get savedMeasurementContext =>
      _savedMeasurementContext;
  double? get changePercent => _changePercent;
  int get elapsedSeconds => _elapsedSeconds;
  bool get measuring =>
      _measurementActive && _baselineTimer != null ||
      _measurementActive &&
          _baselineBpm != null &&
          _saveStatus == HeartSaveStatus.idle;

  static Future<bool> _requestSensorPermissions() async {
    final permissionStatuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    return !permissionStatuses.values.any((status) => !status.isGranted);
  }

  /// A shared connection starts a fresh measurement without reconnecting BLE.
  void beginMeasurement({
    HeartMeasurementContext measurementContext =
        HeartMeasurementContext.general,
  }) {
    if (_disposed) return;
    _session++;
    _stopMeasurement(clearBaseline: true);
    _measurementActive = true;
    _elapsedSeconds = 0;
    _saveStatus = HeartSaveStatus.idle;
    _savedBpm = null;
    _savedAt = null;
    _measurementContext = measurementContext;
    _savedMeasurementContext = HeartMeasurementContext.general;
    _changePercent = null;
    if (_acceptSamples) _watchSignal();
    notifyListeners();
  }

  void _watchSignal() {
    _signalTimer?.cancel();
    if (!_measurementActive || _saveStatus != HeartSaveStatus.idle) return;
    _signalTimer = Timer(_signalTimeout, () {
      if (_disposed ||
          !_measurementActive ||
          _saveStatus != HeartSaveStatus.idle) {
        return;
      }
      _acceptSamples = false;
      _stopMeasurement(clearBaseline: true);
      unawaited(_polar.stopStreaming());
      _set(HeartSensorStatus.failed);
    });
  }

  void endMeasurement() {
    _session++;
    _measurementActive = false;
    _measurementContext = HeartMeasurementContext.general;
    _stopMeasurement(clearBaseline: true);
  }

  HeartSensorStatus get status => _status;
  int? get bpm => _bpm;

  /// 남은 배터리 (0~100). 기기가 아직 안 알려줬으면 null이다.
  /// **0으로 두지 않는다** — 0%는 "다 닳았다"는 뜻이라 모른다는 것과 다르다.
  int? get battery => _battery;

  /// 20% 아래면 미리 알려 준다. 재는 중에 꺼지면 그 측정을 잃는다.
  bool get batteryLow => _battery != null && _battery! <= 20;
  String? get deviceId => _deviceId;
  DateTime? get lastReadAt => _lastReadAt;

  /// 잰 값들. 새 화면의 "가장 낮게 / 가장 높게"가 이걸 쓴다.
  List<int> get samples => List.unmodifiable(_samples);

  int? get lowest =>
      _samples.isEmpty ? null : _samples.reduce((a, b) => a < b ? a : b);
  int? get highest =>
      _samples.isEmpty ? null : _samples.reduce((a, b) => a > b ? a : b);

  void _set(HeartSensorStatus status) {
    if (_disposed) return;
    _status = status;
    notifyListeners();
  }

  /// 센서를 찾아 붙고 심박 스트림을 연다.
  Future<void> start({
    bool measure = true,
    HeartMeasurementContext measurementContext =
        HeartMeasurementContext.general,
  }) async {
    if (_disposed || _connecting) return;
    _connecting = true;
    _acceptSamples = false;
    beginMeasurement(measurementContext: measurementContext);
    _measurementActive = measure;
    final session = _session;
    _set(HeartSensorStatus.connecting);

    try {
      if (!await _requestPermissions()) {
        _set(HeartSensorStatus.failed);
        return;
      }
      if (_disposed || session != _session) return;

      _stopMeasurement(clearBaseline: true);
      await _polar.stopStreaming();
      final previousDeviceId = _deviceId;
      if (previousDeviceId != null) {
        // 심박 신호만 끊긴 경우 BLE 연결까지 끊고 다시 검색하면, SDK의
        // 늦은 disconnect 이벤트가 새 스트림을 다시 닫을 수 있다. 먼저
        // 현재 연결에서 HR 스트림만 다시 열고, 그것이 실패할 때만 실제
        // 장치 검색·재연결로 내려간다.
        try {
          _acceptSamples = true;
          await _polar.startHrStreaming(previousDeviceId);
          if (_disposed || session != _session || !_acceptSamples) return;
          _set(HeartSensorStatus.streaming);
          _watchSignal();
          return;
        } catch (_) {
          _acceptSamples = false;
          await _polar.stopStreaming();
        }
        try {
          await _polar.disconnectFromDevice(previousDeviceId);
        } catch (_) {
          // 이미 끊긴 기기여도 새 검색은 계속한다.
        }
        _deviceId = null;
      }

      final deviceId = await _polar.findDeviceId(
        targetName: 'Polar Verity Sense',
        targetDeviceId: PolarService.defaultDeviceId,
      );
      if (_disposed || session != _session) return;
      await _polar.connectToDevice(deviceId);
      if (_disposed || session != _session) {
        await _polar.disconnectFromDevice(deviceId);
        return;
      }
      _deviceId = deviceId;
      _acceptSamples = true;
      await _polar.startHrStreaming(deviceId);

      if (_disposed || session != _session || !_acceptSamples) return;
      _deviceId = deviceId;
      _set(HeartSensorStatus.streaming);
      _watchSignal();
    } catch (_) {
      if (_disposed || session != _session) return;
      _acceptSamples = false;
      _stopMeasurement(clearBaseline: true);
      _set(HeartSensorStatus.failed);
    } finally {
      _connecting = false;
    }
  }

  void _subscribeToPolarStreams() {
    _subscriptions.add(
      _polar.currentBpmStream.listen((bpm) {
        if (_disposed || !_acceptSamples || bpm == null || bpm <= 0) return;
        // 데이터셋은 운영 기록과 따로 모은다.
        _datasetCollector.addPolarBpm(
          bpm,
          deviceId: _deviceId ?? PolarService.defaultDeviceId,
        );
        _bpm = bpm;
        _lastReadAt = DateTime.now();
        _watchSignal();
        if (!_measurementActive || _saveStatus != HeartSaveStatus.idle) {
          notifyListeners();
          return;
        }
        _samples.add(bpm);
        if (_samples.length > _sampleWindow) _samples.removeAt(0);
        if (_isBaselineMeasuring) _baselineSamples.add(bpm);
        if (_baselineBpm == null && !_isBaselineMeasuring) {
          _startBaselineMeasurement(bpm);
        }
        notifyListeners();
      }),
    );
    _subscriptions.add(
      _polar.averageBpmStream.listen((average) {
        if (_disposed ||
            !_acceptSamples ||
            !_measurementActive ||
            average == null ||
            !average.isFinite ||
            average <= 0 ||
            _baselineBpm == null ||
            _saveStatus != HeartSaveStatus.idle) {
          return;
        }
        _currentAverageBpm = average;
        _changePercent = heartRateChangePercent(
          baseline: _baselineBpm,
          currentAverage: _currentAverageBpm,
        );
        _elapsedSeconds = 45;
        _progressTimer?.cancel();
        _signalTimer?.cancel();
        // One completed window per measurement. The button never posts again.
        _polar.stopAverageMonitoring();
        unawaited(_sendAverageBpm(average));
      }),
    );
    _subscriptions.add(
      _polar.batteryLevelStream.listen((level) {
        if (_disposed) return;
        _battery = level;
        notifyListeners();
      }),
    );
    _subscriptions.add(
      _polar.deviceDisconnectedStream.listen((_) {
        _acceptSamples = false;
        _stopMeasurement(clearBaseline: true);
        _set(HeartSensorStatus.disconnected);
      }),
    );
    _subscriptions.add(
      _polar.errorStream.listen((_) {
        _acceptSamples = false;
        _stopMeasurement(clearBaseline: true);
        _set(HeartSensorStatus.failed);
      }),
    );
  }

  void _startBaselineMeasurement(int firstBpm) {
    _polar.stopAverageMonitoring();
    _baselineTimer?.cancel();
    _baselineSamples
      ..clear()
      ..add(firstBpm);
    _baselineBpm = null;
    _currentAverageBpm = null;
    _isBaselineMeasuring = true;
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed) return;
      // Time alone cannot complete a measurement; a full-window event must arrive.
      _elapsedSeconds = (_elapsedSeconds + 1).clamp(0, 44);
      notifyListeners();
    });
    _baselineTimer = Timer(const Duration(seconds: 15), _completeBaseline);
  }

  void _completeBaseline() {
    if (_disposed) return;
    final baseline = averageValidHeartRates(_baselineSamples);
    _baselineSamples.clear();
    _baselineBpm = baseline;
    _isBaselineMeasuring = false;
    _baselineTimer = null;
    if (baseline != null && baseline > 0) {
      // baseline 표본과 섞이지 않는 새로운 30초 창을 시작한다.
      _polar.startAverageMonitoring();
    }
  }

  void _stopMeasurement({required bool clearBaseline}) {
    _signalTimer?.cancel();
    _progressTimer?.cancel();
    _bpm = null;
    _samples.clear();
    _baselineTimer?.cancel();
    _baselineTimer = null;
    _isBaselineMeasuring = false;
    _baselineSamples.clear();
    _currentAverageBpm = null;
    if (clearBaseline) _baselineBpm = null;
    _polar.stopAverageMonitoring();
  }

  /// 30초 평균만 서버로 올린다. 매 초 값을 올리면 기록이 잡음이 된다.
  Future<void> _sendAverageBpm(double average) async {
    final session = _session;
    final measurementContext = _measurementContext;
    _saveStatus = HeartSaveStatus.saving;
    notifyListeners();
    final userId = MvpSession.userId.trim();
    if (userId.isEmpty) {
      _saveStatus = HeartSaveStatus.failed;
      notifyListeners();
      return;
    }
    try {
      final response = await _apiClient.post(
        '/api/v1/biosignal/heart-rate',
        body: {
          'user_id': userId,
          'bpm': average.round(),
          'device_id': _deviceId ?? PolarService.defaultDeviceId,
          'source': 'POLAR_30S_AVERAGE',
          'measurement_context': measurementContext.value,
        },
      );
      if (_disposed || session != _session) return;
      // Existing HeartRateResponse contract, not merely a successful HTTP status.
      if (response is Map<String, dynamic> &&
          response['heart_rate_log_id'] is int &&
          (response['heart_rate_log_id'] as int) > 0 &&
          response['bpm'] is int &&
          response['bpm'] == average.round() &&
          response['measured_at'] is String &&
          DateTime.tryParse(response['measured_at'] as String) != null) {
        _savedBpm = response['bpm'] as int;
        _savedAt = DateTime.parse(response['measured_at'] as String);
        _savedMeasurementContext = measurementContext;
        _saveStatus = HeartSaveStatus.saved;
      } else {
        _saveStatus = HeartSaveStatus.unknown;
      }
    } on ApiException catch (error) {
      if (_disposed || session != _session) return;
      final status = error.statusCode;
      _saveStatus =
          status != null && status >= 400 && status < 500 && status != 408
          ? HeartSaveStatus.failed
          : HeartSaveStatus.unknown;
    } catch (_) {
      if (_disposed || session != _session) return;
      _saveStatus = HeartSaveStatus.unknown;
    }
    if (!_disposed && session == _session) notifyListeners();
  }

  /// 연결을 끊되 이 객체는 다시 쓸 수 있게 남겨 둔다.
  ///
  /// [dispose]와 다르다. 어르신이 "연결 끊기"를 누른 뒤 다시 "기기 찾기"를
  /// 누를 수 있어야 하므로, 여기서 스트림 컨트롤러까지 닫지는 않는다.
  Future<void> stop() async {
    _session++;
    _measurementActive = false;
    _measurementContext = HeartMeasurementContext.general;
    if (_saveStatus == HeartSaveStatus.saving) {
      _saveStatus = HeartSaveStatus.unknown;
    }
    _acceptSamples = false;
    _stopMeasurement(clearBaseline: true);
    await _polar.stopStreaming();
    final deviceId = _deviceId;
    if (deviceId != null) {
      await _polar.disconnectFromDevice(deviceId);
    }
    _deviceId = null;
    _bpm = null;
    _battery = null;
    _samples.clear();
    _set(HeartSensorStatus.idle);
  }

  @override
  void dispose() {
    _disposed = true;
    _session++;
    _progressTimer?.cancel();
    _baselineTimer?.cancel();
    _signalTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    unawaited(_polar.stopStreaming());
    final deviceId = _deviceId;
    if (deviceId != null) {
      unawaited(_polar.disconnectFromDevice(deviceId));
    }
    unawaited(_polar.dispose());
    super.dispose();
  }
}
