import 'dart:async';

import 'package:alkong_yakong/core/network/api_client.dart';
import 'package:alkong_yakong/core/widgets/senior_button.dart';
import 'package:alkong_yakong/features/biosignal/application/heart_sensor.dart';
import 'package:alkong_yakong/features/biosignal/data/biosignal_dataset_collector.dart';
import 'package:alkong_yakong/features/biosignal/data/polar_service.dart';
import 'package:alkong_yakong/features/biosignal/domain/heart_data.dart';
import 'package:alkong_yakong/features/biosignal/presentation/screens/measure_screen.dart';
import 'package:alkong_yakong/features/biosignal/presentation/screens/saved_screen.dart';
// Already supplied by flutter_test; do not change application dependencies.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:polar/polar.dart';

// Only the hardware/network edges are fake; production timers and averaging run.
// Keep cancellation futures inside the fake-clock zone (broadcast streams may
// otherwise return a cached completed future created outside that zone).
class TestStream<T> extends Stream<T> {
  TestStream(this.source);
  final Stream<T> source;
  @override
  StreamSubscription<T> listen(
    void Function(T)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => TestSubscription(
    source.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    ),
  );
}

class TestSubscription<T> implements StreamSubscription<T> {
  TestSubscription(this.source);
  final StreamSubscription<T> source;
  @override
  Future<void> cancel() {
    unawaited(source.cancel());
    return Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// A mutable hardware fake; production Polar remains unchanged.
// ignore: must_be_immutable
class FakePolar implements Polar {
  static const device = PolarDeviceInfo(
    deviceId: 'test-device',
    address: '',
    rssi: -40,
    name: 'Polar Verity Sense',
    isConnectable: true,
  );
  final disconnected =
      StreamController<PolarDeviceDisconnectedEvent>.broadcast();
  final features = StreamController<PolarSdkFeatureReadyEvent>.broadcast();
  StreamController<PolarHrData> hr = StreamController<PolarHrData>.broadcast();
  int subscriptions = 0;
  int searches = 0;
  int connections = 0;
  int disconnections = 0;

  @override
  Stream<PolarDeviceDisconnectedEvent> get deviceDisconnected =>
      TestStream(disconnected.stream);
  @override
  Stream<PolarBatteryLevelEvent> get batteryLevel => const Stream.empty();
  @override
  Stream<PolarSdkFeatureReadyEvent> get sdkFeatureReady =>
      TestStream(features.stream);
  @override
  Stream<PolarDeviceInfo> searchForDevice() {
    searches++;
    return Stream.value(device);
  }

  @override
  Future<void> connectToDevice(
    String identifier, {
    bool requestPermissions = true,
  }) async {
    connections++;
    features.add(PolarSdkFeatureReadyEvent(identifier, PolarSdkFeature.hr));
  }

  @override
  Future<void> disconnectFromDevice(String identifier) async {
    disconnections++;
  }

  @override
  Stream<PolarHrData> startHrStreaming(String identifier) {
    subscriptions++;
    if (hr.isClosed) hr = StreamController<PolarHrData>.broadcast();
    return TestStream(hr.stream);
  }

  void sample(
    int bpm, {
    bool contactStatus = true,
    bool contactStatusSupported = true,
  }) => hr.add(
    PolarHrData(
      samples: [
        PolarHrSample(
          hr: bpm,
          ppgQuality: 0,
          correctedHr: bpm,
          rrsMs: const [],
          contactStatus: contactStatus,
          contactStatusSupported: contactStatusSupported,
        ),
      ],
    ),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeApi implements ApiClient {
  final requests = <Map<String, dynamic>>[];
  final pending = <Completer<dynamic>>[];
  final paths = <String>[];
  @override
  Future<dynamic> post(
    String path, {
    required Map<String, dynamic> body,
    Duration timeout = const Duration(seconds: 45),
  }) {
    paths.add(path);
    requests.add(body);
    final result = Completer<dynamic>();
    pending.add(result);
    return result.future;
  }

  void succeed(int index) => pending[index].complete({
    'heart_rate_log_id': index + 1,
    'bpm': requests[index]['bpm'],
    'measured_at': '2026-01-01T12:00:00',
    'baseline': null,
    'abnormal_event': null,
  });
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class NoDataset implements BiosignalDatasetCollector {
  @override
  void addPolarBpm(int bpm, {required String deviceId}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Rig {
  final sdk = FakePolar();
  final api = FakeApi();
  late final sensor = HeartSensor(
    polar: PolarService(polar: sdk),
    apiClient: api,
    datasetCollector: NoDataset(),
    requestPermissions: () async => true,
  );
  void start(
    FakeAsync clock, {
    HeartMeasurementContext measurementContext =
        HeartMeasurementContext.general,
  }) {
    unawaited(sensor.start(measurementContext: measurementContext));
    clock.flushMicrotasks();
    expect(sensor.status, HeartSensorStatus.streaming);
  }

  void baseline(FakeAsync clock) {
    for (var i = 0; i < 3; i++) {
      sdk.sample(60);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 5));
    }
  }

  void window(FakeAsync clock) {
    baseline(clock);
    for (var i = 0; i < 6; i++) {
      sdk.sample(81);
      sdk.sample(82);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 5));
    }
  }

  Future<void> widgetWindow(WidgetTester tester) async {
    for (var i = 0; i < 9; i++) {
      if (i < 3) {
        sdk.sample(60);
      } else {
        sdk.sample(81);
        sdk.sample(82);
      }
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
    }
  }
}

void main() {
  test(
    'connection only cannot save; measuring starts explicitly without reconnect',
    () {
      fakeAsync((clock) {
        final r = Rig();
        unawaited(r.sensor.start(measure: false));
        clock.flushMicrotasks();
        r.window(clock);
        expect(r.api.requests, isEmpty);
        expect(r.sensor.elapsedSeconds, 0);
        expect(r.sensor.status, HeartSensorStatus.streaming);
        r.sensor.beginMeasurement();
        r.window(clock);
        expect(r.api.requests, hasLength(1));
        expect(r.sdk.subscriptions, 1);
        r.api.succeed(0);
        clock.flushMicrotasks();
        r.sensor.dispose();
        clock.flushMicrotasks();
      });
    },
  );

  for (final duringBaseline in [true, false]) {
    test(
      'silent signal loss cancels incomplete measurement: baseline=$duringBaseline',
      () {
        fakeAsync((clock) {
          final r = Rig();
          r.start(clock);
          if (!duringBaseline) r.baseline(clock);
          r.sdk.sample(80);
          clock.flushMicrotasks();
          clock.elapse(const Duration(seconds: 10));
          expect(r.sensor.status, HeartSensorStatus.failed);
          expect(r.sensor.bpm, isNull);
          clock.elapse(const Duration(minutes: 1));
          expect(r.api.requests, isEmpty);
          r.start(clock);
          r.window(clock);
          expect(r.api.requests, hasLength(1));
          r.api.succeed(0);
          clock.flushMicrotasks();
          r.sensor.dispose();
          clock.flushMicrotasks();
        });
      },
    );
  }

  test('supported skin-contact loss cancels measurement and never saves', () {
    fakeAsync((clock) {
      final r = Rig();
      r.start(clock);
      r.baseline(clock);
      r.sdk.sample(62, contactStatus: false);
      clock.flushMicrotasks();

      expect(r.sensor.status, HeartSensorStatus.failed);
      expect(r.sensor.bpm, isNull);
      clock.elapse(const Duration(minutes: 1));
      expect(r.api.requests, isEmpty);
      r.sensor.dispose();
      clock.flushMicrotasks();
    });
  });

  test(
    'unsupported contact flag does not falsely reject a valid HR sample',
    () {
      fakeAsync((clock) {
        final r = Rig();
        r.start(clock);
        r.sdk.sample(62, contactStatus: false, contactStatusSupported: false);
        clock.flushMicrotasks();

        expect(r.sensor.status, HeartSensorStatus.streaming);
        expect(r.sensor.bpm, 62);
        r.sensor.dispose();
        clock.flushMicrotasks();
      });
    },
  );

  test(
    'delayed HR never completes on wall time; baseline excluded; saved average frozen',
    () {
      fakeAsync((clock) {
        final r = Rig();
        r.start(clock);
        clock.elapse(const Duration(minutes: 2));
        expect(r.sensor.elapsedSeconds, 0);
        expect(r.api.requests, isEmpty);
        expect(r.sensor.status, HeartSensorStatus.failed);
        r.start(clock);
        r.window(clock);
        expect(r.api.requests.single['bpm'], 82);
        expect(r.api.paths.single, '/api/v1/biosignal/heart-rate');
        expect(r.api.requests.single['source'], 'POLAR_30S_AVERAGE');
        expect(r.api.requests.single['measurement_context'], 'general');
        expect(r.sensor.changePercent, closeTo(35.833333, 0.0001));
        expect(r.sensor.saveStatus, HeartSaveStatus.saving);
        expect(r.sensor.savedBpm, isNull);
        r.api.succeed(0);
        clock.flushMicrotasks();
        r.sdk.sample(99);
        clock.flushMicrotasks();
        clock.elapse(const Duration(minutes: 2));
        expect(r.sensor.savedBpm, 82);
        expect(r.sensor.saveStatus, HeartSaveStatus.saved);
        expect(r.api.requests, hasLength(1));
        r.sensor.dispose();
        clock.flushMicrotasks();
      });
    },
  );

  for (final context in [
    HeartMeasurementContext.beforeMedication,
    HeartMeasurementContext.afterMedication,
  ]) {
    test(
      '${context.value} is frozen for one upload and next run is general',
      () {
        fakeAsync((clock) {
          final r = Rig();
          r.start(clock, measurementContext: context);
          r.window(clock);
          expect(r.api.requests.single['measurement_context'], context.value);
          r.api.succeed(0);
          clock.flushMicrotasks();
          expect(r.sensor.savedMeasurementContext, context);
          r.sensor.beginMeasurement();
          expect(r.sensor.measurementContext, HeartMeasurementContext.general);
          r.sensor.dispose();
          clock.flushMicrotasks();
        });
      },
    );
  }

  for (final failure in [
    const ApiException('rejected', statusCode: 404),
    const ApiException('network timeout'),
    const ApiException('server failure', statusCode: 500),
  ]) {
    test(
      'API ${failure.statusCode} never reports saved or automatically retries',
      () {
        fakeAsync((clock) {
          final r = Rig();
          r.start(clock);
          r.window(clock);
          r.api.pending.single.completeError(failure);
          clock.flushMicrotasks();
          expect(
            r.sensor.saveStatus,
            failure.statusCode == 404
                ? HeartSaveStatus.failed
                : HeartSaveStatus.unknown,
          );
          expect(r.sensor.savedBpm, isNull);
          clock.elapse(const Duration(minutes: 2));
          expect(r.api.requests, hasLength(1));
          r.sensor.dispose();
          clock.flushMicrotasks();
        });
      },
    );
  }

  for (final response in [
    null,
    <String, dynamic>{},
    {'heart_rate_log_id': 1, 'bpm': 99, 'measured_at': '2026-01-01T12:00:00'},
  ]) {
    test('invalid success contract $response is unknown, not saved', () {
      fakeAsync((clock) {
        final r = Rig();
        r.start(clock);
        r.window(clock);
        r.api.pending.single.complete(response);
        clock.flushMicrotasks();
        expect(r.sensor.saveStatus, HeartSaveStatus.unknown);
        r.sensor.dispose();
        clock.flushMicrotasks();
      });
    });
  }

  for (final event in ['disconnect', 'done', 'error']) {
    test(
      '$event clears live BPM, cancels partial window and permits fresh reconnect',
      () {
        fakeAsync((clock) {
          final r = Rig();
          r.start(clock);
          r.baseline(clock);
          r.sdk.sample(80);
          clock.flushMicrotasks();
          if (event == 'disconnect') {
            r.sdk.disconnected.add(
              const PolarDeviceDisconnectedEvent(FakePolar.device, false),
            );
          } else if (event == 'done') {
            unawaited(r.sdk.hr.close());
          } else {
            r.sdk.hr.addError(StateError('test failure'));
          }
          clock.flushMicrotasks();
          clock.elapse(const Duration(seconds: 40));
          expect(r.sensor.bpm, isNull);
          expect(r.api.requests, isEmpty);
          expect(r.sensor.status, isNot(HeartSensorStatus.streaming));
          r.start(clock);
          r.window(clock);
          expect(r.sdk.subscriptions, 2);
          expect(r.api.requests, hasLength(1));
          r.api.succeed(0);
          clock.flushMicrotasks();
          r.sdk.disconnected.add(
            const PolarDeviceDisconnectedEvent(FakePolar.device, false),
          );
          clock.flushMicrotasks();
          expect(r.sensor.savedBpm, 82);
          expect(r.sensor.saveStatus, HeartSaveStatus.saved);
          r.sensor.dispose();
          clock.flushMicrotasks();
        });
      },
    );
  }

  test(
    'late upload response cannot complete a restarted or closed measurement',
    () {
      fakeAsync((clock) {
        final r = Rig();
        r.start(clock);
        r.window(clock);
        r.sensor.beginMeasurement();
        r.api.succeed(0);
        clock.flushMicrotasks();
        expect(r.sensor.saveStatus, HeartSaveStatus.idle);
        expect(r.sensor.savedBpm, isNull);
        r.window(clock);
        r.sensor.endMeasurement();
        r.api.succeed(1);
        clock.flushMicrotasks();
        expect(r.sensor.savedBpm, isNull);
        r.sensor.dispose();
        clock.flushMicrotasks();
      });
    },
  );

  test('disposing during upload ignores late success', () {
    fakeAsync((clock) {
      final r = Rig();
      r.start(clock);
      r.window(clock);
      r.sensor.dispose();
      r.api.succeed(0);
      clock.flushMicrotasks();
      expect(r.sensor.savedBpm, isNull);
    });
  });

  for (final rejected in [true, false]) {
    testWidgets('save failure UI preserves uncertainty: rejected=$rejected', (
      tester,
    ) async {
      final r = Rig();
      await r.sensor.start();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: MeasureScreen(sensor: r.sensor)),
        ),
      );
      await r.widgetWindow(tester);
      r.api.pending.single.completeError(
        ApiException('test failure', statusCode: rejected ? 404 : null),
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.text(rejected ? '기록을 저장하지 못했어요' : '저장 여부를 확인하지 못했어요'),
        findsOneWidget,
      );
      expect(find.text('저장된 기록 확인하기'), findsNothing);
      expect(find.byType(SavedScreen), findsNothing);
      await tester.pump(const Duration(minutes: 1));
      expect(r.api.requests, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      r.sensor.dispose();
      await tester.pump();
    });
  }

  testWidgets('skin-contact loss retries the existing BLE connection first', (
    tester,
  ) async {
    final r = Rig();
    await r.sensor.start();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: MeasureScreen(sensor: r.sensor)),
      ),
    );
    r.sdk.sample(62, contactStatus: false);
    await tester.pump();
    await tester.pump();

    expect(find.text('지금은 심장 박동을\n재지 못하고 있어요'), findsOneWidget);
    expect(find.text('다시 연결하기'), findsOneWidget);
    expect(find.text('폴라 센서로 재고 있어요'), findsNothing);
    expect(r.api.requests, isEmpty);

    await tester.tap(find.text('다시 연결하기'));
    await tester.pump();
    await tester.pump();
    expect(r.sensor.status, HeartSensorStatus.streaming);
    expect(r.sdk.subscriptions, 2);
    expect(r.sdk.searches, 1);
    expect(r.sdk.connections, 1);
    expect(r.sdk.disconnections, 0);
    r.sdk.sample(64);
    await tester.pump();
    expect(r.sensor.bpm, 64);

    await tester.pumpWidget(const SizedBox());
    r.sensor.dispose();
    await tester.pump();
  });

  testWidgets(
    'screen waits for saved response; repeated button taps never POST',
    (tester) async {
      final r = Rig();
      await r.sensor.start();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: MeasureScreen(sensor: r.sensor)),
        ),
      );
      await tester.pump(const Duration(seconds: 65));
      expect(find.text('저장된 기록 확인하기'), findsNothing);
      await r.sensor.start();
      await r.widgetWindow(tester);
      expect(r.sensor.saveStatus, HeartSaveStatus.saving);
      await tester.pump();
      expect(find.text('저장 확인 중이에요'), findsWidgets);
      expect(find.text('잘 저장되었어요'), findsNothing);
      r.api.succeed(0);
      await tester.pump();
      r.sdk.disconnected.add(
        const PolarDeviceDisconnectedEvent(FakePolar.device, false),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('–'), findsNWidgets(2));
      await tester.ensureVisible(find.text('저장된 기록 확인하기'));
      final button = tester.widget<SeniorButton>(
        find.ancestor(
          of: find.text('저장된 기록 확인하기'),
          matching: find.byType(SeniorButton),
        ),
      );
      button.onPressed!();
      button.onPressed!();
      await tester.pumpAndSettle();
      expect(find.byType(SavedScreen), findsOneWidget);
      expect(find.text('82회 / 분 · 평소 심박 측정 · 서버에 저장된 심박수'), findsOneWidget);
      expect(find.text('보호자 자동 알림은 지원하지 않아요'), findsNothing);
      expect(r.api.requests, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      r.sensor.dispose();
      await tester.pump();
    },
  );
}
