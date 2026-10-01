import 'dart:convert';

import 'package:alkong_yakong/core/network/api_config.dart';
import 'package:alkong_yakong/core/session/mvp_session.dart';
import 'package:alkong_yakong/features/dur_analysis/presentation/screens/dur_analysis_screen.dart';
import 'package:alkong_yakong/features/medication/application/medication_controller.dart';
import 'package:alkong_yakong/features/medication/domain/medication_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _EmptyMedicationController extends MedicationController {
  @override
  TodayMedication build() => const TodayMedication(
    doses: [],
    guardianRelation: '보호자',
    guardianName: '가족',
  );
}

void main() {
  test('Android uses Render unless API_BASE_URL is explicitly overridden', () {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      const override = String.fromEnvironment('API_BASE_URL');
      expect(
        ApiConfig.baseUrl,
        override.isEmpty ? ApiConfig.productionBaseUrl : override,
      );
    } finally {
      debugDefaultTargetPlatformOverride = previousPlatform;
    }
  });

  testWidgets('confirmed pair uses two tiles without changing risk result', (
    tester,
  ) async {
    final previousUserId = MvpSession.userId;
    MvpSession.userId = 'synthetic-user';
    addTearDown(() => MvpSession.userId = previousUserId);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final client = MockClient((request) async {
      expect(request.url.path, '/api/v1/guardians/users/synthetic-user');
      return http.Response(jsonEncode([]), 200);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            medicationProvider.overrideWith(_EmptyMedicationController.new),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: const DurAnalysisScreen(
              initialResult: {
                'analysis_complete': true,
                'assessment_status': 'RISK_FOUND',
                'has_risk': true,
                'matches': [
                  {
                    'type': '병용금기',
                    'medicine_names_a': ['합성 약 A'],
                    'medicine_names_b': ['합성 약 B'],
                    'easy_line_a': '가려움을 줄이는 데 쓰는 약이에요',
                    'easy_line_b': '심장 박동을 조절하는 약이에요',
                    'why_easy': '두 약을 함께 사용할 때 확인이 필요해요.',
                    'source_label': '합성 시험 자료',
                  },
                ],
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('합성 약 A'), findsOneWidget);
      expect(find.text('합성 약 B'), findsOneWidget);
      expect(find.text('+'), findsOneWidget);
      expect(find.text('같이'), findsOneWidget);
      expect(find.text('두 약을 함께 사용할 때 확인이 필요해요.'), findsOneWidget);
      expect(find.text('확인했어요'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, () => client);
  });

  testWidgets('incomplete result never becomes a no-risk message', (
    tester,
  ) async {
    final previousUserId = MvpSession.userId;
    MvpSession.userId = 'synthetic-user';
    addTearDown(() => MvpSession.userId = previousUserId);
    final client = MockClient((request) async => http.Response('[]', 200));
    await http.runWithClient(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            medicationProvider.overrideWith(_EmptyMedicationController.new),
          ],
          child: const MaterialApp(
            home: DurAnalysisScreen(initialResult: {'matches': []}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('약은 등록됐지만 함께먹기 확인을 마치지 못했어요.'), findsOneWidget);
      expect(find.text('확인한 범위에서 약끼리 함께먹기 주의 항목은 없어요.'), findsNothing);
    }, () => client);
  });
}
