// lib/biosignal/presentation/biosignal_notifier.dart
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/polar_service.dart';
import '../data/biosignal_repository.dart';
import '../domain/hrv_calculator.dart';
import '../domain/biosignal_state.dart';

class BiosignalNotifier extends Notifier<BiosignalState> {
  StreamSubscription? _hrSub;
  StreamSubscription? _ppiSub;
  StreamSubscription? _accSub;
  Timer? _anomalyTimer;
  final List<int> _ppiBuffer = [];

  @override
  BiosignalState build() => BiosignalState();

  void startMonitoring(String deviceId) async {
    final polarService = ref.read(polarServiceProvider);
    final calculator = HrvCalculator();
    await polarService.requestPermissions();

    // 1. 심박수 스트림 구독
    _hrSub = polarService.heartRateStream(deviceId).listen((hr) {
      state = state.copyWith(currentHr: hr);
      _checkAnomalyThreshold(hr);
    });

    // 2. PPI 스트림 구독 및 RMSSD 계산 (30초 주기 가공)
    _ppiSub = polarService.ppiStream(deviceId).listen((ppi) {
      if (ppi > 0) _ppiBuffer.add(ppi);
      if (_ppiBuffer.length >= 30) {
        final filtered = calculator.filterPpi(_ppiBuffer);
        final rmssd = calculator.calculateRmssd(filtered);
        state = state.copyWith(currentRmssd: rmssd);
        _ppiBuffer.clear();
      }
    });

    // 3. 가속도 스트림 구독 (변인 통제)
    _accSub = polarService.accStream(deviceId).listen((acc) {
      if (acc.samples.isEmpty) return;
      // 단순 예시: 3축 벡터 변화량으로 움직임 임계치 판정
      final bool moving =
          (acc.samples.first.x.abs() > 500 || acc.samples.first.y.abs() > 500);
      state = state.copyWith(isMoving: moving);
    });
  }

  void _checkAnomalyThreshold(int hr) {
    // 안정 상태에서 심박수가 100을 초과할 때 (Step 1 & Step 2)
    if (!state.isMoving && hr > 100) {
      _anomalyTimer ??= Timer(const Duration(seconds: 10), () async {
        state = state.copyWith(isAnomalyDetected: true, isAnalyzing: true);

        try {
          // 3단계 및 4단계 조립: 백엔드로 데이터 송신 및 Gemini 분석 요청
          final repository = ref.read(biosignalRepositoryProvider);
          final resultReport = await repository.sendBiosignalData(
            hr: state.currentHr,
            rmssd: state.currentRmssd,
            drugList: ['아토르바스타틴'], // 처방약 데이터 연동 전 임시 더미 데이터
          );

          // 5단계 준비: 분석 완료 후 상태 업데이트 및 화면 표시 준비
          state = state.copyWith(aiReport: resultReport, isAnalyzing: false);
        } catch (e) {
          state = state.copyWith(
            aiReport: "분석 중 오류가 발생했습니다: $e",
            isAnalyzing: false,
          );
        }
      });
    } else {
      // 조건을 벗어나면 타이머 초기화 (위양성 방지)
      _anomalyTimer?.cancel();
      _anomalyTimer = null;
      if (state.isAnomalyDetected) {
        state = state.copyWith(isAnomalyDetected: false, aiReport: "");
      }
    }
  }

  void stopMonitoring() {
    _hrSub?.cancel();
    _ppiSub?.cancel();
    _accSub?.cancel();
    _anomalyTimer?.cancel();
  }
}

final biosignalProvider = NotifierProvider<BiosignalNotifier, BiosignalState>(
  () => BiosignalNotifier(),
);
