import 'dart:convert';
import 'package:alkong_yakong/core/network/api_client.dart';
import 'package:alkong_yakong/core/session/mvp_session.dart';
import 'package:alkong_yakong/features/medication/application/medication_controller.dart';
import 'package:alkong_yakong/features/prescription/domain/registration_result.dart';
import 'package:alkong_yakong/features/prescription/presentation/screens/manual_medicine_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final complete = <String, dynamic>{
    'analysis_complete': true,
    'assessment_status': 'SAFE',
    'has_risk': false,
    'matches': [],
  };
  test('DUR zero, risk, incomplete, nullable and malformed stay distinct', () {
    expect(registrationDurComplete(complete), isTrue);
    expect(
      registrationDurComplete({
        ...complete,
        'assessment_status': 'RISK_FOUND',
        'has_risk': true,
        'matches': [
          {'type': '병용금기'},
        ],
      }),
      isTrue,
    );
    for (final raw in [
      null,
      {},
      {'matches': []},
      {...complete, 'matches': null},
      {
        ...complete,
        'matches': [null],
      },
      {...complete, 'analysis_complete': false},
      {...complete, 'has_risk': null},
      {...complete, 'incomplete': true},
    ]) {
      final result = registrationDurResult(raw);
      expect(result['assessment_status'], 'INCOMPLETE');
      expect(result['has_risk'], isNull);
    }
  });

  test(
    'refresh failure opt-in throws; old callers keep state, no POST',
    () async {
      var posts = 0;
      final client = MockClient((r) async {
        if (r.method == 'POST') posts++;
        return http.Response(
          '{"detail":"synthetic"}',
          500,
          headers: {'content-type': 'application/json'},
        );
      });
      final container = ProviderContainer(
        overrides: [
          medicationProvider.overrideWith(
            () => MedicationController(apiClient: ApiClient(client: client)),
          ),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(medicationProvider.notifier);
      final before = container.read(medicationProvider);
      await controller.refreshFromServer();
      await expectLater(
        controller.refreshFromServer(throwOnError: true),
        throwsA(isA<ApiException>()),
      );
      expect(container.read(medicationProvider), same(before));
      expect(posts, 0);
    },
  );

  for (final failedPath in ['today-medicines', '/medicines']) {
    testWidgets(
      'manual registration stays saved when $failedPath refresh fails',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        MvpSession.userId = 'synthetic-user';
        var posts = 0;
        Map<String, dynamic>? saved;
        final client = MockClient((request) async {
          Object body;
          var status = 200;
          if (request.method == 'POST') {
            posts++;
            expect(request.url.path, '/api/v1/prescriptions/confirm');
            body = {
              'registered': true,
              'prescription_id': 'synthetic-prescription',
              'items': [],
              'dur_result': {
                ...complete,
                'analysis_complete': false,
                'has_risk': null,
              },
            };
          } else if (request.url.path.endsWith('/lookup')) {
            body = {
              'items': [
                {'medicine_code': 'synthetic-code', 'display_name': '합성 제품'},
              ],
            };
          } else if (request.url.path.endsWith(failedPath)) {
            status = 500;
            body = {'detail': 'synthetic failure'};
          } else if (request.url.path.endsWith('/medicines')) {
            body = {'medicines': []};
          } else {
            body = {'doses': []};
          }
          return http.Response(
            jsonEncode(body),
            status,
            headers: {'content-type': 'application/json'},
          );
        });
        await http.runWithClient(() async {
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                home: ManualMedicineScreen(onSaved: (value) => saved = value),
              ),
            ),
          );
          await tester.enterText(find.byType(TextField).first, '합성');
          // 이름을 적고 잠깐 기다리면 공식 약 목록을 찾아 온다.
          await tester.pump(const Duration(milliseconds: 800));
          await tester.pumpAndSettle();
          await tester.tap(find.text('합성 제품'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField).last, '0.5정');
          await tester.tap(find.text('1번'));
          await tester.tap(find.text('3일'));
          // 드시는 때를 골라야 등록된다 — 시간을 지어내지 않는다.
          await tester.tap(find.text('아침'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('이 약 등록하기'));
          await tester.tap(find.text('이 약 등록하기'));
          await tester.pumpAndSettle();
          expect(posts, 1);
          expect(saved?['assessment_status'], 'INCOMPLETE');
          expect(find.text('약은 등록됐지만 목록을 다시 불러와야 해요.'), findsOneWidget);
          expect(find.text('공식 약으로 확인되지 않아 등록하지 못했어요.'), findsNothing);
          await tester.pump(const Duration(seconds: 5));
          expect(posts, 1);
        }, () => client);
      },
    );
  }
}
