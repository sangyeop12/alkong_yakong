import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';

class BiosignalDatasetCollector {
  BiosignalDatasetCollector({ApiClient? apiClient})
    : _apiClient = apiClient ?? ApiClient();

  static const Duration _window = Duration(seconds: 5);

  final ApiClient _apiClient;
  final List<int> _samples = <int>[];
  DateTime? _windowStartedAt;
  bool _isFlushing = false;

  void addPolarBpm(int bpm, {required String deviceId}) {
    if (bpm <= 0) return;
    final now = DateTime.now();
    _windowStartedAt ??= now;
    _samples.add(bpm);

    if (now.difference(_windowStartedAt!) >= _window && !_isFlushing) {
      final windowStartedAt = _windowStartedAt!;
      final windowSamples = List<int>.of(_samples);
      _samples.clear();
      _windowStartedAt = now;
      unawaited(_flush(windowSamples, deviceId, windowStartedAt, now));
    }
  }

  void clearSignalWindow() {
    _samples.clear();
    _windowStartedAt = null;
  }

  Future<void> _flush(
    List<int> samples,
    String deviceId,
    DateTime windowStartedAt,
    DateTime measuredAt,
  ) async {
    if (samples.isEmpty) return;
    _isFlushing = true;
    try {
      final active = await _apiClient.get(
        '/api/v1/biosignal-test/sessions/active',
      );
      if (active is! Map<String, dynamic>) return;
      final sessionId = active['session_id']?.toString();
      if (sessionId == null || sessionId.isEmpty) return;
      final sessionStartedAt = DateTime.tryParse(
        active['started_at']?.toString() ?? '',
      );
      if (sessionStartedAt == null ||
          sessionStartedAt.isAfter(windowStartedAt)) {
        return;
      }

      final total = samples.fold<int>(0, (sum, bpm) => sum + bpm);
      await _apiClient.post(
        '/api/v1/biosignal-test/samples',
        body: {
          'session_id': sessionId,
          'bpm': (total / samples.length).round(),
          'measured_at': measuredAt.toIso8601String(),
          'device_id': deviceId,
          'source': 'POLAR_DATASET_5S',
          'is_synthetic': false,
        },
      );
    } catch (error) {
      debugPrint('[POLAR_DATASET] 5s sample skipped: $error');
    } finally {
      _isFlushing = false;
    }
  }
}
