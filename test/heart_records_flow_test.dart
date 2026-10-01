import 'dart:async';
import 'dart:convert';

import 'package:alkong_yakong/core/constants/app_colors.dart';
import 'package:alkong_yakong/core/network/api_client.dart';
import 'package:alkong_yakong/core/theme/app_theme.dart';
import 'package:alkong_yakong/core/widgets/senior_button.dart';
import 'package:alkong_yakong/core/widgets/senior_card.dart';
import 'package:alkong_yakong/core/widgets/senior_feedback.dart';
import 'package:alkong_yakong/core/widgets/senior_header.dart';
import 'package:alkong_yakong/features/biosignal/data/heart_repository.dart';
import 'package:alkong_yakong/features/biosignal/domain/heart_data.dart';
import 'package:alkong_yakong/features/biosignal/domain/heart_time.dart';
import 'package:alkong_yakong/features/biosignal/presentation/screens/heart_screen.dart';
import 'package:alkong_yakong/features/biosignal/presentation/screens/measure_screen.dart';
import 'package:alkong_yakong/features/biosignal/presentation/screens/monthly_heart_screen.dart';
import 'package:alkong_yakong/features/biosignal/presentation/screens/saved_screen.dart';
import 'package:alkong_yakong/features/medication/domain/medication_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'polar_save_flow_test.dart' show Rig;

Map<String, dynamic> body({int? bpm}) {
  final now = DateTime.now();
  return {
    'today': {},
    'week': [],
    'month': [],
    'period_date':
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
    'readings': [
      if (bpm != null)
        {'id': 1, 'bpm': bpm, 'measured_at': now.toUtc().toIso8601String()},
    ],
  };
}

Map<String, dynamic> bodyWithReading({
  required int bpm,
  required String measuredAt,
  String? measurementContext,
  String? periodDate,
}) {
  final parsed = DateTime.parse(measuredAt).toLocal();
  final reading = <String, dynamic>{
    'id': 1,
    'bpm': bpm,
    'measured_at': measuredAt,
  };
  if (measurementContext != null) {
    reading['measurement_context'] = measurementContext;
  }
  return {
    'today': {},
    'week': [],
    'month': [],
    'period_date':
        periodDate ??
        '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}',
    'readings': [reading],
  };
}

http.Response response({int? bpm, int status = 200}) => http.Response(
  jsonEncode(body(bpm: bpm)),
  status,
  headers: {'content-type': 'application/json'},
);

Widget wrap(Widget screen) => ProviderScope(
  child: MaterialApp(theme: AppTheme.build(), home: screen),
);

HeartData monthlyData(
  List<HeartReading> readings, {
  List<HeartMonthDay> month = const [],
}) => HeartData(
  readings: readings,
  periodDate: DateTime(2026, 9, 28),
  today: const HeartPair(),
  todaySlotLabel: '',
  beforeAt: '',
  afterAt: '',
  week: const [],
  month: month,
  streakDays: 0,
  bestStreakDays: 0,
  anomaly: null,
  sensorConnected: false,
  sensorBattery: null,
  sensorLastReadAt: '',
  notifyGuardian: false,
);

GoRouter heartFlowRouter({
  required HeartRepository repository,
  required Rig rig,
  bool directMeasureFromHome = false,
}) => GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, _) => Scaffold(
        body: TextButton(
          onPressed: () {
            if (directMeasureFromHome) {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => MeasureScreen(
                    sensor: rig.sensor,
                    returnToPreviousScreen: true,
                  ),
                ),
              );
              return;
            }
            context.go('/biosignal');
          },
          child: const Text('홈에서 심박수 관리 열기'),
        ),
      ),
    ),
    GoRoute(
      path: '/biosignal',
      builder: (_, _) => HeartScreen(
        repository: repository,
        sensor: rig.sensor,
        routeBasedMeasurement: true,
      ),
      routes: [
        GoRoute(
          path: 'measure',
          builder: (_, state) {
            final args = state.extra! as HeartMeasureRouteArgs;
            return MeasureScreen(
              guardianTitle: args.guardianTitle,
              sensor: args.sensor,
              measurementContext: args.measurementContext,
              onSaved: args.onSaved,
              returnToPreviousScreen: true,
            );
          },
        ),
        GoRoute(
          path: 'saved',
          builder: (_, state) {
            final args = state.extra! as HeartSavedRouteArgs;
            return SavedScreen(
              bpm: args.bpm,
              savedAt: args.savedAt,
              measurementContext: args.measurementContext,
              guardianTitle: args.guardianTitle,
              onConfirmed: args.onSaved,
              returnToPreviousScreen: true,
            );
          },
        ),
      ],
    ),
  ],
);

void main() {
  testWidgets('saved confirmation leaves a first-route completion screen', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/saved',
      routes: [
        GoRoute(
          path: '/saved',
          builder: (_, _) =>
              const SavedScreen(bpm: 92, guardianTitle: '합성 보호자'),
        ),
        GoRoute(
          path: '/biosignal',
          builder: (_, _) => const Scaffold(body: Text('심박수 관리로 돌아옴')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          theme: AppTheme.build(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SavedScreen), findsOneWidget);
    await tester.ensureVisible(find.text('확인했어요'));
    await tester.tap(find.text('확인했어요'));
    await tester.pumpAndSettle();
    expect(find.text('심박수 관리로 돌아옴'), findsOneWidget);
    expect(find.byType(SavedScreen), findsNothing);
  });

  testWidgets('monthly incomplete medication record has no conclusion', (
    tester,
  ) async {
    final data = HeartData(
      readings: [
        HeartReading(
          id: 1,
          bpm: 81,
          measuredAt: DateTime(2026, 9, 1, 10),
          measurementContext: HeartMeasurementContext.afterMedication,
        ),
      ],
      periodDate: DateTime(2026, 9, 28),
      today: const HeartPair(),
      todaySlotLabel: '',
      beforeAt: '',
      afterAt: '',
      week: const [],
      month: const [
        HeartMonthDay(1, HeartPair(after: 81)),
        HeartMonthDay(3, HeartPair(after: 79)),
      ],
      streakDays: 2,
      bestStreakDays: 2,
      anomaly: null,
      sensorConnected: false,
      sensorBattery: null,
      sensorLastReadAt: '',
      notifyGuardian: false,
    );
    await tester.pumpWidget(
      wrap(MonthlyHeartScreen(data: data, now: DateTime(2026, 9, 28))),
    );
    await tester.pumpAndSettle();
    expect(find.text('복약 전·후를 비교할 기록이 아직 부족해요.'), findsOneWidget);
    expect(find.text('일째'), findsNothing);
    expect(find.textContaining('가장 길었던 기록'), findsNothing);
    expect(find.textContaining('정상'), findsNothing);
    expect(find.textContaining('비슷했어요'), findsNothing);
  });

  testWidgets(
    'monthly without guardian connection shows no shared-view claim or invented name',
    (tester) async {
      final repository = HeartRepository(
        apiClient: ApiClient(
          client: MockClient((_) async => response(bpm: 98)),
        ),
      );
      final data = await repository.fetch(userId: 'synthetic');
      // No medication provider or guardian lookup is needed to render records.
      await tester.pumpWidget(
        MaterialApp(home: MonthlyHeartScreen(data: data!)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('98회/분'), findsOneWidget);
      expect(find.textContaining('같이 보고 있어요'), findsNothing);
      expect(find.textContaining('김이박'), findsNothing);
    },
  );

  testWidgets(
    'monthly comparison ignores general and incomplete medication contexts',
    (tester) async {
      final cases = <List<HeartReading>>[
        [HeartReading(id: 1, bpm: 90, measuredAt: DateTime(2026, 9, 8, 9))],
        [
          HeartReading(
            id: 2,
            bpm: 91,
            measuredAt: DateTime(2026, 9, 8, 9),
            measurementContext: HeartMeasurementContext.beforeMedication,
          ),
        ],
        [
          HeartReading(
            id: 3,
            bpm: 89,
            measuredAt: DateTime(2026, 9, 8, 10),
            measurementContext: HeartMeasurementContext.afterMedication,
          ),
        ],
      ];

      for (final readings in cases) {
        await tester.pumpWidget(
          wrap(
            MonthlyHeartScreen(
              data: monthlyData(
                readings,
                // 서버 요약에 값이 있더라도 명시적인 측정 목적이 우선이다.
                month: const [
                  HeartMonthDay(8, HeartPair(before: 90, after: 89)),
                ],
              ),
              now: DateTime(2026, 9, 28),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('복약 전·후를 비교할 기록이 아직 부족해요.'), findsOneWidget);
        expect(find.text('주별 평균'), findsNothing);
        expect(find.textContaining('비슷했어요'), findsNothing);
        expect(find.textContaining('내려갔'), findsNothing);
      }
    },
  );

  testWidgets(
    'one explicit before/after pair shows one-week bars without a conclusion',
    (tester) async {
      final data = monthlyData([
        HeartReading(
          id: 1,
          bpm: 90,
          measuredAt: DateTime(2026, 9, 8, 9),
          measurementContext: HeartMeasurementContext.beforeMedication,
        ),
        HeartReading(
          id: 2,
          bpm: 91,
          measuredAt: DateTime(2026, 9, 8, 10),
          measurementContext: HeartMeasurementContext.afterMedication,
        ),
      ]);

      await tester.pumpWidget(
        wrap(MonthlyHeartScreen(data: data, now: DateTime(2026, 9, 28))),
      );
      await tester.pumpAndSettle();

      expect(find.text('1회/분 높았어요', skipOffstage: false), findsOneWidget);
      expect(find.text('복약 전  90회/분', skipOffstage: false), findsOneWidget);
      expect(find.text('복약 후  91회/분', skipOffstage: false), findsOneWidget);
      expect(find.text('일반 범위', skipOffstage: false), findsNWidgets(2));
      expect(find.text('비교 기록 1주', skipOffstage: false), findsOneWidget);
      expect(
        find.text('아직 경향을 판단하기 어려워요', skipOffstage: false),
        findsOneWidget,
      );
      expect(find.textContaining('약의 영향으로 단정할 수 없어요.'), findsOneWidget);
      expect(find.text('주별 평균'), findsOneWidget);
      expect(find.text('단위: 회/분 · 비교 가능한 주 1주'), findsOneWidget);
      expect(find.text('복약 전 평균'), findsOneWidget);
      expect(find.text('복약 후 평균'), findsOneWidget);
      expect(find.text('9/7~9/13'), findsOneWidget);
      expect(find.textContaining('비슷했어요'), findsNothing);
      expect(find.textContaining('효과'), findsNothing);
      expect(find.textContaining('약 때문에'), findsNothing);
    },
  );

  testWidgets(
    'monthly summary classifies averages and emphasizes after value',
    (tester) async {
      final data = monthlyData([
        HeartReading(
          id: 1,
          bpm: 54,
          measuredAt: DateTime(2026, 9, 28, 16),
          measurementContext: HeartMeasurementContext.beforeMedication,
        ),
        HeartReading(
          id: 2,
          bpm: 64,
          measuredAt: DateTime(2026, 9, 28, 16, 1),
          measurementContext: HeartMeasurementContext.afterMedication,
        ),
      ]);

      await tester.pumpWidget(
        wrap(MonthlyHeartScreen(data: data, now: DateTime(2026, 9, 30))),
      );
      await tester.pumpAndSettle();

      expect(find.text('복약 후 평균 심박수가', skipOffstage: false), findsOneWidget);
      expect(find.text('10회/분 높았어요', skipOffstage: false), findsOneWidget);
      expect(find.text('복약 전  54회/분', skipOffstage: false), findsOneWidget);
      expect(find.text('복약 후  64회/분', skipOffstage: false), findsOneWidget);
      expect(find.text('느린 범위', skipOffstage: false), findsOneWidget);
      expect(find.text('일반 범위', skipOffstage: false), findsOneWidget);

      final afterValue = tester.widget<Text>(
        find.byKey(const Key('weekly-after-value'), skipOffstage: false),
      );
      expect(afterValue.data, '64');
      expect(afterValue.style?.color, AppColors.point);

      final valuesLabel = tester.widget<Text>(
        find.byKey(const Key('weekly-values-label'), skipOffstage: false),
      );
      final spans = (valuesLabel.textSpan as TextSpan).children!;
      expect((spans.last as TextSpan).text, '후 64');
      expect((spans.last as TextSpan).style?.color, AppColors.point);
    },
  );

  testWidgets('multiple comparable weeks show units, legend, and periods', (
    tester,
  ) async {
    final data = monthlyData([
      HeartReading(
        id: 1,
        bpm: 90,
        measuredAt: DateTime(2026, 9, 1, 9),
        measurementContext: HeartMeasurementContext.beforeMedication,
      ),
      HeartReading(
        id: 2,
        bpm: 88,
        measuredAt: DateTime(2026, 9, 1, 10),
        measurementContext: HeartMeasurementContext.afterMedication,
      ),
      HeartReading(
        id: 3,
        bpm: 92,
        measuredAt: DateTime(2026, 9, 8, 9),
        measurementContext: HeartMeasurementContext.beforeMedication,
      ),
      HeartReading(
        id: 4,
        bpm: 91,
        measuredAt: DateTime(2026, 9, 8, 10),
        measurementContext: HeartMeasurementContext.afterMedication,
      ),
    ]);

    for (final width in <double>[320, 360]) {
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: wrap(
            MonthlyHeartScreen(data: data, now: DateTime(2026, 9, 28)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('주별 평균'), findsOneWidget);
      expect(find.text('단위: 회/분 · 비교 가능한 주 2주'), findsOneWidget);
      expect(find.text('복약 전 평균'), findsOneWidget);
      expect(find.text('복약 후 평균'), findsOneWidget);
      expect(find.text('8/31~9/6'), findsOneWidget);
      expect(find.text('9/7~9/13'), findsOneWidget);
      expect(find.textContaining('비슷했어요'), findsNothing);
      expect(find.textContaining('내려갔'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'monthly first record stays below header on narrow large-text screens',
    (tester) async {
      final data = monthlyData([
        HeartReading(id: 1, bpm: 98, measuredAt: DateTime(2026, 9, 22, 14, 42)),
      ]);

      for (final width in <double>[320, 360]) {
        tester.view.physicalSize = Size(width, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: wrap(
              MonthlyHeartScreen(data: data, now: DateTime(2026, 9, 28)),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final headerBottom = tester.getBottomLeft(find.byType(SeniorHeader)).dy;
        final recordTop = tester.getTopLeft(find.textContaining('98회/분')).dy;
        expect(recordTop, greaterThanOrEqualTo(headerBottom));
        expect(tester.takeException(), isNull);
      }
    },
  );

  test(
    'UTC 05:42 displays Korean 14:42, preserving midnight/month/week boundary',
    () {
      tzdata.initializeTimeZones();
      final seoul = tz.getLocation('Asia/Seoul');
      DateTime localize(DateTime at) => tz.TZDateTime.from(at, seoul);
      expect(
        heartSavedTimeLabel(
          DateTime.parse('2026-09-18T05:42:00Z'),
          now: DateTime.parse('2026-09-18T06:00:00Z'),
          localize: localize,
        ),
        '오늘 오후 2시 42분',
      );
      expect(
        heartSavedTimeLabel(
          DateTime.parse('2026-05-31T15:00:00Z'),
          now: DateTime.parse('2026-05-31T15:01:00Z'),
          localize: localize,
        ),
        '오늘 오전 12시 0분',
      );
      expect(
        heartSavedTimeLabel(
          DateTime.parse('2026-05-31T14:59:00Z'),
          now: DateTime.parse('2026-05-31T15:01:00Z'),
          localize: localize,
        ),
        '2026년 5월 31일 오후 11시 59분',
      );
    },
  );

  testWidgets(
    'standalone record shown in week/month; tabs refresh with GET only; no sharing claim',
    (tester) async {
      var gets = 0;
      var fail = false;
      final repository = HeartRepository(
        apiClient: ApiClient(
          client: MockClient((request) async {
            expect(request.method, 'GET');
            gets++;
            return response(bpm: 98, status: fail ? 503 : 200);
          }),
        ),
      );
      await tester.pumpWidget(
        wrap(HeartScreen(repository: repository, guardianTitle: '합성 보호자')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('98회/분'), findsWidgets);
      expect(find.text('평소 심박 측정'), findsWidgets);
      expect(find.textContaining('비교할 자료는 부족'), findsNothing);
      expect(find.text('지난 기록 보기'), findsNothing);
      expect(find.widgetWithText(SeniorSegmented, '이번 주'), findsOneWidget);
      expect(find.widgetWithText(SeniorSegmented, '한 달'), findsOneWidget);
      expect(find.text('지금 측정'), findsOneWidget);
      expect(find.text('폴라 센서'), findsOneWidget);
      expect(find.textContaining('에게 바로 알려요'), findsNothing);
      expect(gets, 1);
      await tester.tap(find.text('한 달'));
      await tester.pumpAndSettle();
      expect(find.byType(MonthlyHeartScreen), findsOneWidget);
      expect(find.textContaining('98회/분'), findsOneWidget);
      expect(find.textContaining('같이 보고 있어요'), findsNothing);
      expect(gets, 2);
      await tester.tap(find.text('이번 주'));
      await tester.pumpAndSettle();
      expect(gets, 3);
      fail = true;
      await tester.tap(find.text('한 달'));
      await tester.pumpAndSettle();
      expect(find.text('심박수 기록을 불러오지 못했어요'), findsOneWidget);
      expect(find.text('아직 측정 기록이 없어요'), findsNothing);
      expect(find.textContaining('같이 보고 있어요'), findsNothing);
    },
  );

  testWidgets(
    'today card shows a general reading with value, local time, and purpose',
    (tester) async {
      final now = DateTime.now();
      final measuredAt = DateTime(now.year, now.month, now.day, 14, 42);
      final repository = HeartRepository(
        apiClient: ApiClient(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode(
                bodyWithReading(
                  bpm: 92,
                  measuredAt: measuredAt.toUtc().toIso8601String(),
                  measurementContext: 'general',
                ),
              ),
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        ),
      );

      await tester.pumpWidget(wrap(HeartScreen(repository: repository)));
      await tester.pumpAndSettle();

      final todayCard = find.ancestor(
        of: find.text('오늘 측정'),
        matching: find.byType(SeniorCard),
      );
      expect(
        find.descendant(of: todayCard, matching: find.text('92회/분')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: todayCard, matching: find.text('평소 심박 측정')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: todayCard, matching: find.text('일반 범위')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: todayCard,
          matching: find.text('성인이 쉬고 있을 때의 일반적인 기준이에요.'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: todayCard,
          matching: find.text(DoseSlot.absoluteTime(measuredAt)),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: todayCard, matching: find.text('오늘은 아직 재지 않았어요')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'today medication comparison shows ranges, difference, and caveat',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final now = DateTime.now();
      final repository = HeartRepository(
        apiClient: ApiClient(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'today': {'before': 54, 'after': 64},
                'today_slot_label': '복약',
                'before_at': '16:00',
                'after_at': '16:01',
                'week': [],
                'month': [],
                'period_date':
                    '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
                'readings': [],
              }),
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        ),
      );

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: wrap(HeartScreen(repository: repository)),
        ),
      );
      await tester.pumpAndSettle();

      final todayCard = find.ancestor(
        of: find.text('오늘 측정'),
        matching: find.byType(SeniorCard),
      );
      expect(
        find.descendant(of: todayCard, matching: find.text('느린 범위')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: todayCard, matching: find.text('일반 범위')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: todayCard,
          matching: find.text('약 먹은 후 10회/분 높았어요'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: todayCard,
          matching: find.text('성인이 쉬고 있을 때의 일반적인 기준이에요.'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: todayCard,
          matching: find.text('한 번의 비교만으로 약의 영향이라고 판단하기 어려워요.'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'legacy reading without measurement context appears as a usual heart reading',
    (tester) async {
      final now = DateTime.now();
      final measuredAt = DateTime(now.year, now.month, now.day, 9, 5);
      final repository = HeartRepository(
        apiClient: ApiClient(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode(
                bodyWithReading(
                  bpm: 74,
                  measuredAt: measuredAt.toUtc().toIso8601String(),
                ),
              ),
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        ),
      );

      await tester.pumpWidget(wrap(HeartScreen(repository: repository)));
      await tester.pumpAndSettle();

      expect(find.text('평소 심박 측정'), findsWidgets);
      expect(find.text('74회/분'), findsOneWidget);
      expect(find.text('오늘은 아직 재지 않았어요'), findsNothing);
    },
  );

  testWidgets('outdated response cannot replace newer query', (tester) async {
    final pending = <Completer<http.Response>>[];
    final repository = HeartRepository(
      apiClient: ApiClient(
        client: MockClient((request) {
          final result = Completer<http.Response>();
          pending.add(result);
          return result.future;
        }),
      ),
    );
    await tester.pumpWidget(
      wrap(HeartScreen(repository: repository, guardianTitle: '합성 보호자')),
    );
    await tester.pump();
    await tester.tap(find.text('이번 주'));
    await tester.pump();
    expect(pending.length, 2);
    pending[1].complete(response(bpm: 98));
    await tester.pumpAndSettle();
    pending[0].complete(response(bpm: 71));
    await tester.pumpAndSettle();
    expect(find.textContaining('98회/분'), findsWidgets);
    expect(find.textContaining('71회/분'), findsNothing);
  });

  testWidgets(
    'saved measurement return reloads server records without another POST',
    (tester) async {
      final rig = Rig();
      await rig.sensor.start(measure: false);
      var gets = 0;
      var stored = false;
      final repository = HeartRepository(
        apiClient: ApiClient(
          client: MockClient((request) async {
            expect(request.method, 'GET');
            gets++;
            return response(bpm: stored ? 82 : null);
          }),
        ),
      );
      await tester.pumpWidget(
        wrap(
          HeartScreen(
            repository: repository,
            sensor: rig.sensor,
            guardianTitle: '합성 보호자',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('아직 측정 기록이 없어요'), findsOneWidget);
      await tester.ensureVisible(find.text('지금 측정'));
      await tester.tap(find.text('지금 측정'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await rig.widgetWindow(tester);
      stored = true;
      rig.api.succeed(0);
      await tester.pump();
      await tester.pump();
      await tester.ensureVisible(find.text('저장된 기록 확인하기'));
      await tester.tap(find.text('저장된 기록 확인하기'));
      await tester.pumpAndSettle();
      expect(find.byType(SavedScreen), findsOneWidget);
      await tester.ensureVisible(find.text('확인했어요'));
      await tester.tap(find.text('확인했어요'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('82회/분'), -250);
      expect(find.text('82회/분'), findsOneWidget);
      expect(gets, greaterThanOrEqualTo(2));
      expect(rig.api.requests, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      rig.sensor.dispose();
      await tester.pump();
    },
  );

  for (final purpose in HeartMeasurementContext.values) {
    testWidgets(
      'real GoRouter flow returns ${purpose.value} measurement to heart screen',
      (tester) async {
        final rig = Rig();
        await rig.sensor.start(measure: false);
        var stored = false;
        var gets = 0;
        final measuredAt = DateTime.now();
        final repository = HeartRepository(
          apiClient: ApiClient(
            client: MockClient((request) async {
              expect(request.method, 'GET');
              gets++;
              if (!stored) return response();
              final payload = bodyWithReading(
                bpm: 82,
                measuredAt: measuredAt.toUtc().toIso8601String(),
                measurementContext: purpose.value,
              );
              if (purpose == HeartMeasurementContext.beforeMedication) {
                payload['today'] = {'before': 82};
                payload['before_at'] = '10:30';
              } else if (purpose == HeartMeasurementContext.afterMedication) {
                payload['today'] = {'after': 82};
                payload['after_at'] = '10:30';
              }
              return http.Response(
                jsonEncode(payload),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          ),
        );
        final router = heartFlowRouter(repository: repository, rig: rig);
        addTearDown(router.dispose);

        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp.router(
              theme: AppTheme.build(),
              routerConfig: router,
            ),
          ),
        );
        await tester.tap(find.text('홈에서 심박수 관리 열기'));
        await tester.pumpAndSettle();
        if (purpose != HeartMeasurementContext.general) {
          await tester.ensureVisible(find.text(purpose.label));
          await tester.tap(find.text(purpose.label));
        }
        await tester.ensureVisible(find.text('지금 측정'));
        await tester.tap(find.text('지금 측정'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await rig.widgetWindow(tester);
        stored = true;
        rig.api.succeed(0);
        await tester.pump();
        await tester.pump();
        await tester.ensureVisible(find.text('저장된 기록 확인하기'));
        await tester.tap(find.text('저장된 기록 확인하기'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('확인했어요'));
        await tester.pumpAndSettle();

        expect(router.routeInformationProvider.value.uri.path, '/biosignal');
        expect(find.text('홈에서 심박수 관리 열기'), findsNothing);
        expect(find.byType(HeartScreen), findsOneWidget);
        expect(find.byType(SavedScreen), findsNothing);
        final readingsCard = find.ancestor(
          of: find.text('저장된 심박 기록'),
          matching: find.byType(SeniorCard),
        );
        expect(
          find.descendant(
            of: readingsCard,
            matching: find.textContaining('82회/분'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: readingsCard, matching: find.text(purpose.label)),
          findsOneWidget,
        );
        expect(gets, 2);
        expect(rig.api.requests, hasLength(1));

        await tester.pumpWidget(const SizedBox());
        rig.sensor.dispose();
        await tester.pump();
      },
    );
  }

  for (final saveFailure in <({String label, bool rejected})>[
    (label: '기록을 저장하지 못했어요', rejected: true),
    (label: '저장 여부를 확인하지 못했어요', rejected: false),
  ]) {
    testWidgets(
      'real GoRouter keeps ${saveFailure.label} out of success navigation',
      (tester) async {
        final rig = Rig();
        await rig.sensor.start(measure: false);
        final repository = HeartRepository(
          apiClient: ApiClient(client: MockClient((_) async => response())),
        );
        final router = heartFlowRouter(repository: repository, rig: rig);
        addTearDown(router.dispose);

        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp.router(
              theme: AppTheme.build(),
              routerConfig: router,
            ),
          ),
        );
        await tester.tap(find.text('홈에서 심박수 관리 열기'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('지금 측정'));
        await tester.tap(find.text('지금 측정'));
        await tester.pump(const Duration(milliseconds: 400));
        await rig.widgetWindow(tester);
        if (saveFailure.rejected) {
          rig.api.pending.single.completeError(
            const ApiException('synthetic rejection', statusCode: 400),
          );
        } else {
          rig.api.pending.single.complete(null);
        }
        await tester.pump();
        await tester.pump();

        expect(find.text(saveFailure.label), findsOneWidget);
        expect(find.byType(SavedScreen), findsNothing);
        expect(router.routeInformationProvider.value.uri.path, '/biosignal');
        await tester.ensureVisible(find.text('그만두기'));
        await tester.tap(find.text('그만두기'));
        await tester.pumpAndSettle();

        expect(router.routeInformationProvider.value.uri.path, '/biosignal');
        expect(find.byType(HeartScreen), findsOneWidget);
        expect(find.byType(MeasureScreen), findsNothing);
        expect(find.textContaining('82회/분'), findsNothing);

        await tester.pumpWidget(const SizedBox());
        rig.sensor.dispose();
        await tester.pump();
      },
    );
  }

  testWidgets(
    'direct home measurement also finishes on refreshed heart screen',
    (tester) async {
      final rig = Rig();
      await rig.sensor.start(measure: false);
      var stored = false;
      var gets = 0;
      final repository = HeartRepository(
        apiClient: ApiClient(
          client: MockClient((request) async {
            expect(request.method, 'GET');
            gets++;
            return response(bpm: stored ? 82 : null);
          }),
        ),
      );
      final router = heartFlowRouter(
        repository: repository,
        rig: rig,
        directMeasureFromHome: true,
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(
            theme: AppTheme.build(),
            routerConfig: router,
          ),
        ),
      );
      await tester.tap(find.text('홈에서 심박수 관리 열기'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(MeasureScreen), findsOneWidget);
      await rig.widgetWindow(tester);
      stored = true;
      rig.api.succeed(0);
      await tester.pump();
      await tester.pump();
      await tester.ensureVisible(find.text('저장된 기록 확인하기'));
      await tester.tap(find.text('저장된 기록 확인하기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('확인했어요'));
      await tester.pumpAndSettle();

      expect(router.routeInformationProvider.value.uri.path, '/biosignal');
      expect(find.byType(HeartScreen), findsOneWidget);
      expect(find.byType(MeasureScreen), findsNothing);
      expect(find.byType(SavedScreen), findsNothing);
      await tester.scrollUntilVisible(find.text('82회/분'), -250);
      expect(find.text('82회/분'), findsOneWidget);
      expect(gets, greaterThanOrEqualTo(1));
      expect(rig.api.requests, hasLength(1));

      await tester.pumpWidget(const SizedBox());
      rig.sensor.dispose();
      await tester.pump();
    },
  );

  testWidgets('real GoRouter cancellation returns to heart without saving', (
    tester,
  ) async {
    final rig = Rig();
    await rig.sensor.start(measure: false);
    final repository = HeartRepository(
      apiClient: ApiClient(client: MockClient((_) async => response())),
    );
    final router = heartFlowRouter(repository: repository, rig: rig);
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          theme: AppTheme.build(),
          routerConfig: router,
        ),
      ),
    );
    await tester.tap(find.text('홈에서 심박수 관리 열기'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('지금 측정'));
    await tester.tap(find.text('지금 측정'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MeasureScreen), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(MeasureScreen),
        matching: find.byType(SeniorBackButton),
      ),
    );
    await tester.pumpAndSettle();

    expect(router.routeInformationProvider.value.uri.path, '/biosignal');
    expect(find.byType(HeartScreen), findsOneWidget);
    expect(find.byType(MeasureScreen), findsNothing);
    expect(find.byType(SavedScreen), findsNothing);
    expect(rig.api.requests, isEmpty);

    await tester.pumpWidget(const SizedBox());
    rig.sensor.dispose();
    await tester.pump();
  });

  testWidgets(
    'measurement purpose is selected before start and resets to general',
    (tester) async {
      final rig = Rig();
      await rig.sensor.start(measure: false);
      final repository = HeartRepository(
        apiClient: ApiClient(client: MockClient((_) async => response())),
      );
      await tester.pumpWidget(
        wrap(HeartScreen(repository: repository, sensor: rig.sensor)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('복약 전 측정'));
      await tester.tap(find.text('복약 전 측정'));
      await tester.ensureVisible(find.text('지금 측정'));
      final startButton = tester.widget<SeniorButton>(
        find.ancestor(
          of: find.text('지금 측정'),
          matching: find.byType(SeniorButton),
        ),
      );
      startButton.onPressed!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(MeasureScreen), findsOneWidget);
      expect(
        rig.sensor.measurementContext,
        HeartMeasurementContext.beforeMedication,
      );
      expect(
        find.descendant(
          of: find.byType(MeasureScreen),
          matching: find.text('복약 후 측정'),
        ),
        findsNothing,
      );
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      final selector = tester.widget<SeniorSegmented>(
        find.widgetWithText(SeniorSegmented, '평소 심박 측정'),
      );
      expect(selector.index, 0);
      expect(rig.sensor.measurementContext, HeartMeasurementContext.general);
      await tester.pumpWidget(const SizedBox());
      rig.sensor.dispose();
      await tester.pump();
    },
  );

  for (final width in [320.0, 360.0]) {
    testWidgets('measurement purpose fits ${width.toInt()}px at 1.3x text', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final repository = HeartRepository(
        apiClient: ApiClient(client: MockClient((_) async => response())),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.build(),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
              child: HeartScreen(repository: repository),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('측정 목적'), -200);
      expect(find.text('평소 심박 측정'), findsOneWidget);
      expect(find.text('복약 전 측정'), findsOneWidget);
      expect(find.text('복약 후 측정'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
