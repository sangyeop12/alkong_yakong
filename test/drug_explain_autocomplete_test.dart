import 'dart:async';
import 'dart:convert';

import 'package:alkong_yakong/core/network/api_client.dart';
import 'package:alkong_yakong/core/session/mvp_session.dart';
import 'package:alkong_yakong/core/constants/app_colors.dart';
import 'package:alkong_yakong/features/drug_explain/drug_explain_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  http.Response jsonResponse(Object body, {int statusCode = 200}) {
    return http.Response(
      jsonEncode(body),
      statusCode,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  http.Client legacyMedicationClient(http.Client client) {
    return MockClient((request) async {
      final dashboardUrl = request.url.replace(
        path: request.url.path.replaceFirst(
          RegExp(r'/medicines$'),
          '/dashboard',
        ),
      );
      final response = await client.get(dashboardUrl);
      final dashboard = jsonDecode(response.body) as Map<String, dynamic>;
      final rows = <Map<String, dynamic>>[];
      final prescription = dashboard['latest_prescription'];
      if (prescription is Map && prescription['items'] is List) {
        for (final item in prescription['items'] as List) {
          if (item is Map) rows.add(Map<String, dynamic>.from(item));
        }
      }
      final today = dashboard['today_medications'];
      if (today is List) {
        for (final item in today) {
          if (item is Map) rows.add(Map<String, dynamic>.from(item));
        }
      }
      return jsonResponse({'medicines': rows});
    });
  }

  Widget appWith(http.Client client, {http.Client? medicationClient}) {
    return MaterialApp(
      home: DrugExplainScreen(
        apiClient: ApiClient(baseUrl: 'https://team.test', client: client),
        medicationApiClient: ApiClient(
          baseUrl: 'https://medication.test',
          client: medicationClient ?? legacyMedicationClient(client),
        ),
      ),
    );
  }

  // 물어볼 약은 이제 "바꾸기"로 여는 창에서 고른다.
  Future<void> openSubjectDialog(WidgetTester tester) async {
    await tester.tap(find.text('바꾸기'));
    await tester.pumpAndSettle();
  }

  Future<void> pickWheelOption(WidgetTester tester, String label) async {
    final wheel = find.byType(ListWheelScrollView);
    await tester.drag(wheel, const Offset(0, 600));
    await tester.pumpAndSettle();
    final option = find.descendant(of: wheel, matching: find.text(label));
    for (var i = 0; i < 20 && option.evaluate().isEmpty; i++) {
      await tester.drag(wheel, const Offset(0, -66));
      await tester.pumpAndSettle();
    }
    await tester.tap(option);
    await tester.pumpAndSettle();
    await tester.tap(find.text('선택'));
    await tester.pumpAndSettle();
  }

  // 첫 창에서는 일반/전체/약 이름 선택을 고르고, 약 이름은 체크해서 복수 선택한다.
  Future<void> pickSubject(WidgetTester tester, String label) async {
    await openSubjectDialog(tester);
    if (label == '일반 질문' || label == '약 전체') {
      await pickWheelOption(tester, label);
      return;
    }
    await pickWheelOption(tester, '약 이름 선택');
    final checkboxes = find.byType(Checkbox);
    for (var i = 0; i < checkboxes.evaluate().length; i++) {
      final checkbox = tester.widget<Checkbox>(checkboxes.at(i));
      if (checkbox.value == true) {
        await tester.tap(checkboxes.at(i));
        await tester.pumpAndSettle();
      }
    }
    await tester.tap(find.byKey(ValueKey('medicine-selection-$label')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1개 선택'));
    await tester.pumpAndSettle();
  }

  Future<void> pickMedicines(WidgetTester tester, List<String> labels) async {
    await openSubjectDialog(tester);
    await pickWheelOption(tester, '약 이름 선택');
    final checkboxes = find.byType(Checkbox);
    for (var i = 0; i < checkboxes.evaluate().length; i++) {
      final checkbox = tester.widget<Checkbox>(checkboxes.at(i));
      if (checkbox.value == true) {
        await tester.tap(checkboxes.at(i));
        await tester.pumpAndSettle();
      }
    }
    for (final label in labels) {
      await tester.tap(find.byKey(ValueKey('medicine-selection-$label')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('${labels.length}개 선택'));
    await tester.pumpAndSettle();
  }

  Future<void> openOtherMedicineSearch(WidgetTester tester) async {
    await openSubjectDialog(tester);
    await pickWheelOption(tester, '약 이름 선택');
    await tester.tap(find.text('다른 약 검색하기'));
    await tester.pumpAndSettle();
  }

  testWidgets('일반 검색은 팀 서버, 내 복용약은 약 데이터 서버를 사용한다', (tester) async {
    final teamPaths = <String>[];
    final medicationPaths = <String>[];
    final teamClient = MockClient((request) async {
      teamPaths.add(request.url.path);
      return jsonResponse({
        'query': request.url.queryParameters['q'],
        'count': 1,
        'items': [
          {'item_name': '검색약정', 'manufacturer': '제조사', 'item_seq': '900'},
        ],
      });
    });
    final medicationClient = MockClient((request) async {
      medicationPaths.add(request.url.path);
      return jsonResponse({
        'medicines': [
          {
            'medicine_code': '100',
            'product_name': 'OCR등록약정',
            'ingredient': '등록성분',
            'status': 'active',
          },
        ],
      });
    });

    await tester.pumpWidget(
      appWith(teamClient, medicationClient: medicationClient),
    );
    await tester.pumpAndSettle();
    expect(medicationPaths, ['/api/v1/users/mvp-user/medicines']);
    expect(teamPaths, isEmpty);

    await openOtherMedicineSearch(tester);
    await tester.enterText(
      find.byKey(const Key('otherMedicineSearchField')),
      '검색약',
    );
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump();
    expect(teamPaths, ['/api/v1/drugs/search']);
    expect(find.text('검색약정'), findsOneWidget);

    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    await pickSubject(tester, 'OCR등록약정');
    expect(find.text('OCR등록약정'), findsOneWidget);
  });

  testWidgets('약 데이터 서버 목록 실패를 빈 목록으로 숨기지 않는다', (tester) async {
    final teamClient = MockClient((_) async => jsonResponse({'reply': '미사용'}));
    final medicationClient = MockClient(
      (_) async => jsonResponse({'detail': 'failure'}, statusCode: 503),
    );

    await tester.pumpWidget(
      appWith(teamClient, medicationClient: medicationClient),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('HTTP 503'), findsNothing);
    expect(
      find.text('지금은 등록한 약을 불러오지 못했어요.\n잠시 후 다시 시도해 주세요.'),
      findsOneWidget,
    );
    expect(find.text('등록된 처방/복용약이 없습니다.'), findsNothing);
  });

  testWidgets('공식 제품명이 OCR 표시명보다 우선하고 같은 코드 중복을 제거한다', (tester) async {
    final originalOcr = MvpSession.latestOcrItems;
    MvpSession.latestOcrItems = [
      {
        'medicine_code': '20000001',
        'drug_name': '아디팜정',
        'official_product_name': '아디팜정(히드록시진염산염)',
      },
    ];
    addTearDown(() => MvpSession.latestOcrItems = originalOcr);
    Map<String, dynamic>? sent;
    final teamClient = MockClient((request) async {
      if (request.url.path.endsWith('/drug-explain/chat')) {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return jsonResponse({'reply': '공식정보 답변'});
      }
      throw StateError('unexpected team request: ${request.url.path}');
    });
    final medicationClient = MockClient((request) async {
      expect(request.url.path, endsWith('/medicines'));
      return jsonResponse({
        'medicines': [
          {
            'medicine_code': '20000001',
            'product_name': '아디팜정',
            'official_product_name': '아디팜정(히드록시진염산염)',
            'ingredient': '히드록시진염산염',
          },
          {
            'medicine_code': '20000001',
            'product_name': '아디팜정',
            'official_product_name': '아디팜정(히드록시진염산염)',
            'ingredient': '히드록시진염산염',
          },
        ],
      });
    });

    await tester.pumpWidget(
      appWith(teamClient, medicationClient: medicationClient),
    );
    await tester.pumpAndSettle();
    await pickSubject(tester, '아디팜정');
    expect(find.text('아디팜정'), findsOneWidget);
    expect(find.text('아디팜정(히드록시진염산염)'), findsNothing);

    await tester.tap(find.text('어디에 쓰는 약인가요?'));
    await tester.pumpAndSettle();
    expect(sent?['selected_medicine'], {
      'medicine_code': '20000001',
      'product_name': '아디팜정(히드록시진염산염)',
    });
  });

  testWidgets('서로 다른 코드의 같은 표시명은 자동 병합하지 않는다', (tester) async {
    Map<String, dynamic>? sent;
    final teamClient = MockClient((request) async {
      if (request.url.path.endsWith('/drug-explain/chat')) {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return jsonResponse({'reply': '답변'});
      }
      throw StateError('unexpected team request: ${request.url.path}');
    });
    final medicationClient = MockClient((request) async {
      return jsonResponse({
        'medicines': [
          {
            'medicine_code': 'code-a',
            'official_product_name': '같은약정(성분A)',
            'ingredient': '성분A',
          },
          {
            'medicine_code': 'code-b',
            'official_product_name': '같은약정(성분B)',
            'ingredient': '성분B',
          },
        ],
      });
    });

    await tester.pumpWidget(
      appWith(teamClient, medicationClient: medicationClient),
    );
    await tester.pumpAndSettle();
    // 같은 표시명은 하나로 합쳐 전송하지 않고, 기존 모호성 방지 정책으로
    // 공식 품목을 자동 선택하지 않는다.
    await pickSubject(tester, '같은약정');
    expect(find.text('같은약정'), findsOneWidget);
    await tester.tap(find.text('어디에 쓰는 약인가요?'));
    await tester.pumpAndSettle();
    expect(sent, isNotNull);
    expect(sent!.containsKey('selected_medicine'), isFalse);
  });

  testWidgets('코드가 없는 약은 정규화된 표시명으로만 중복을 제거한다', (tester) async {
    final teamClient = MockClient((request) async {
      if (request.url.path.endsWith('/drug-explain/chat')) {
        return jsonResponse({'reply': '답변'});
      }
      throw StateError('unexpected team request: ${request.url.path}');
    });
    final medicationClient = MockClient((request) async {
      return jsonResponse({
        'medicines': [
          {'official_product_name': '무 코드 정'},
          {'official_product_name': '무코드정'},
        ],
      });
    });

    await tester.pumpWidget(
      appWith(teamClient, medicationClient: medicationClient),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('바꾸기'));
    await tester.pumpAndSettle();
    await pickWheelOption(tester, '약 이름 선택');
    expect(find.text('무 코드 정'), findsOneWidget);
    expect(find.text('무코드정'), findsNothing);
  });

  testWidgets('두 글자와 550ms debounce 뒤에만 공식 후보를 검색한다', (tester) async {
    var searchCalls = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [],
        });
      }
      searchCalls++;
      return jsonResponse({
        'query': request.url.queryParameters['q'],
        'count': 1,
        'items': [
          {'item_name': '게보린정', 'manufacturer': '삼진제약(주)', 'item_seq': '1'},
        ],
      });
    });

    await tester.pumpWidget(appWith(client));
    await tester.pump();
    await openOtherMedicineSearch(tester);

    await tester.enterText(
      find.byKey(const Key('otherMedicineSearchField')),
      '게',
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(searchCalls, 0);

    await tester.enterText(
      find.byKey(const Key('otherMedicineSearchField')),
      '게보',
    );
    await tester.pump(const Duration(milliseconds: 549));
    expect(searchCalls, 0);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(searchCalls, 1);
    expect(find.text('게보린정'), findsOneWidget);
    expect(find.text('삼진제약(주)'), findsOneWidget);
  });

  testWidgets('늦게 도착한 이전 검색 결과는 최신 결과를 덮지 않는다', (tester) async {
    final firstResponse = Completer<http.Response>();
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [],
        });
      }
      if (request.url.queryParameters['q'] == '게보') {
        return firstResponse.future;
      }
      return jsonResponse({
        'query': '게보린',
        'count': 1,
        'items': [
          {'item_name': '게보린정', 'manufacturer': '삼진제약(주)', 'item_seq': '1'},
        ],
      });
    });

    await tester.pumpWidget(appWith(client));
    await tester.pump();
    await openOtherMedicineSearch(tester);
    final field = find.byKey(const Key('otherMedicineSearchField'));

    await tester.enterText(field, '게보');
    await tester.pump(const Duration(milliseconds: 550));
    await tester.enterText(field, '게보린');
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump();
    expect(find.text('게보린정'), findsOneWidget);

    firstResponse.complete(
      jsonResponse({
        'query': '게보',
        'count': 1,
        'items': [
          {'item_name': '오래된검색결과', 'manufacturer': '이전제조사', 'item_seq': 'old'},
        ],
      }),
    );
    await tester.pump();
    expect(find.text('게보린정'), findsOneWidget);
    expect(find.text('오래된검색결과'), findsNothing);
  });

  testWidgets('사용자가 고른 공식 품목명이 선택되고 빠른 질문에 사용된다', (tester) async {
    final chatBodies = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [],
        });
      }
      if (request.url.path.endsWith('/drug-explain/chat')) {
        chatBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return jsonResponse({'reply': '복용방법 답변'});
      }
      return jsonResponse({
        'query': '게보',
        'count': 2,
        'items': [
          {'item_name': '게보린정', 'manufacturer': '삼진제약(주)', 'item_seq': '1'},
          {'item_name': '게보린릴랙스연질캡슐', 'manufacturer': '다른제조사', 'item_seq': '2'},
        ],
      });
    });

    await tester.pumpWidget(appWith(client));
    await tester.pump();
    await openOtherMedicineSearch(tester);
    await tester.enterText(
      find.byKey(const Key('otherMedicineSearchField')),
      '게보',
    );
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump();
    await tester.tap(find.text('게보린정'));
    await tester.pumpAndSettle();

    expect(find.text('게보린정'), findsOneWidget);
    await tester.tap(find.text('어떻게 사용하나요?'));
    await tester.pumpAndSettle();
    expect(
      chatBodies.last['message'],
      '이 약은 보통 어떻게 사용하나요? 제가 등록한 사용 방법과 제품의 일반적인 사용법을 구분해서 알려주세요.',
    );
    expect(chatBodies.last['selected_medicine'], {
      'medicine_code': '1',
      'product_name': '게보린정',
    });

    // "약 전체"로 돌렸다가 다시 고르면 공식 품목 코드도 함께 돌아온다.
    await pickSubject(tester, '약 전체');
    expect(find.text('어떻게 사용하나요?'), findsNothing);
    await pickSubject(tester, '게보린정');
    await tester.tap(find.text('어떻게 사용하나요?'));
    await tester.pumpAndSettle();
    expect(chatBodies.last['selected_medicine'], {
      'medicine_code': '1',
      'product_name': '게보린정',
    });
    expect(find.text('복용방법 답변'), findsNWidgets(2));
  });

  testWidgets('공식 code가 있는 저장 약 chip은 selected_medicine을 전송한다', (tester) async {
    Map<String, dynamic>? chatBody;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [
            {'medicine_code': '197900145', 'product_name': '유한메토트렉세이트정'},
          ],
        });
      }
      if (request.url.path.endsWith('/drug-explain/chat')) {
        chatBody = jsonDecode(request.body) as Map<String, dynamic>;
        return jsonResponse({'reply': '공식정보 답변'});
      }
      throw StateError('unexpected request: ${request.url.path}');
    });

    await tester.pumpWidget(appWith(client));
    await tester.pumpAndSettle();
    await pickSubject(tester, '유한메토트렉세이트정');
    await tester.tap(find.text('어디에 쓰는 약인가요?'));
    await tester.pumpAndSettle();

    expect(chatBody?['selected_medicine'], {
      'medicine_code': '197900145',
      'product_name': '유한메토트렉세이트정',
    });
  });

  testWidgets('약 한 가지 빠른 질문 6종은 쉬운 문장과 기존 intent를 전송한다', (tester) async {
    final originalUserId = MvpSession.userId;
    MvpSession.userId = 'quick-question-test-user';
    addTearDown(() => MvpSession.userId = originalUserId);

    final sentMessages = <String>[];
    final sentIntents = <String>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [
            {'product_name': '게보린정'},
          ],
        });
      }
      if (request.url.path.endsWith('/drug-explain/chat')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body.containsKey('selected_medicine'), isFalse);
        sentMessages.add(body['message'] as String);
        sentIntents.add(body['intent'] as String);
        return jsonResponse({'reply': '빠른 질문 답변'});
      }
      throw StateError('unexpected request: ${request.url.path}');
    });
    const expected = <String, String>{
      '어디에 쓰는 약인가요?': '이 약은 어디에 쓰는 약인가요?',
      '어떻게 사용하나요?':
          '이 약은 보통 어떻게 사용하나요? 제가 등록한 사용 방법과 제품의 일반적인 사용법을 구분해서 알려주세요.',
      '무엇을 조심해야 하나요?': '이 약을 사용할 때 무엇을 조심해야 하나요?',
      '사용 뒤 증상이 생기면?': '이 약을 사용한 뒤 평소와 다른 증상이 생기면 어떻게 해야 하나요?',
      '나이에 따라 조심할 점': '제 나이에 이 약을 사용할 때 조심할 점이 있나요?',
      '임신 중에 조심할 점': '임신 중에 이 약을 사용할 때 조심할 점이 있나요?',
    };
    const expectedIntents = <String, String>{
      '어디에 쓰는 약인가요?': 'efficacy',
      '어떻게 사용하나요?': 'dosage',
      '무엇을 조심해야 하나요?': 'precautions',
      '사용 뒤 증상이 생기면?': 'side_effects',
      '나이에 따라 조심할 점': 'age',
      '임신 중에 조심할 점': 'pregnancy',
    };

    for (final entry in expected.entries) {
      await tester.pumpWidget(appWith(client));
      await tester.pumpAndSettle();
      await pickSubject(tester, '게보린정');
      expect(find.text('게보린정'), findsOneWidget);
      final keywordChip = find.widgetWithText(ChoiceChip, entry.key);
      await tester.ensureVisible(keywordChip);
      await tester.tap(keywordChip);
      await tester.pumpAndSettle();
      expect(sentMessages.last, entry.value);
      expect(sentIntents.last, expectedIntents[entry.key]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
    expect(sentMessages, expected.values.toList());
    expect(sentIntents, expectedIntents.values.toList());
  });

  testWidgets('약 한 가지에는 함께먹기 버튼이 없고 약 전체에는 유지된다', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [
            {'medicine_code': '197900145', 'product_name': '유한메토트렉세이트정'},
          ],
        });
      }
      throw StateError('unexpected request: ${request.url.path}');
    });

    await tester.pumpWidget(appWith(client));
    await tester.pumpAndSettle();
    await pickSubject(tester, '유한메토트렉세이트정');
    expect(find.widgetWithText(ChoiceChip, '다른 약과 함께 먹어도 되나요?'), findsNothing);
    await pickSubject(tester, '약 전체');
    expect(find.widgetWithText(ChoiceChip, '같이 먹어도 괜찮나요?'), findsOneWidget);
  });

  testWidgets('두 약 이상 선택하면 선택 범위용 빠른 질문으로 두 약만 전송한다', (tester) async {
    Map<String, dynamic>? chatBody;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [
            {'medicine_code': '111', 'product_name': '첫번째약정'},
            {'medicine_code': '222', 'product_name': '두번째약정'},
            {'medicine_code': '333', 'product_name': '선택안한약정'},
          ],
        });
      }
      if (request.url.path.endsWith('/drug-explain/chat')) {
        chatBody = jsonDecode(request.body) as Map<String, dynamic>;
        return jsonResponse({'reply': '선택한 두 약을 확인했어요.'});
      }
      throw StateError('unexpected request: ${request.url.path}');
    });

    await tester.pumpWidget(appWith(client));
    await tester.pumpAndSettle();
    await pickMedicines(tester, ['첫번째약정', '두번째약정']);

    expect(find.text('첫번째약정 외 1개'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '선택한 약 알려주세요'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '같이 먹어도 괜찮나요?'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '같은 성분의 약이 있나요?'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '약마다 주의할 점은요?'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '어디에 쓰는 약인가요?'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, '같이 먹어도 괜찮나요?'));
    await tester.pumpAndSettle();

    expect(chatBody?['intent'], 'combination');
    expect(chatBody?.containsKey('selected_medicine'), isFalse);
    expect(chatBody?.containsKey('current_medicines'), isFalse);
    expect(chatBody?['selected_medicines'], [
      {'medicine_code': '111', 'product_name': '첫번째약정'},
      {'medicine_code': '222', 'product_name': '두번째약정'},
    ]);
    expect(chatBody?['message'], contains('첫번째약정'));
    expect(chatBody?['message'], contains('두번째약정'));
    expect(chatBody?['message'], isNot(contains('선택안한약정')));

    await tester.enterText(find.byType(TextField), '두 약의 차이를 알려주세요.');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();
    expect(chatBody?['message'], contains('첫번째약정'));
    expect(chatBody?['message'], contains('두번째약정'));
    expect(chatBody?['message'], contains('두 약의 차이를 알려주세요.'));
    expect(chatBody?['message'], isNot(contains('선택안한약정')));
  });

  testWidgets('검색한 약을 기존 선택에 추가해 복수 질문 대상으로 보낸다', (tester) async {
    Map<String, dynamic>? chatBody;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [
            {'medicine_code': '111', 'product_name': '등록약정'},
          ],
        });
      }
      if (request.url.path.endsWith('/drugs/search')) {
        return jsonResponse({
          'query': request.url.queryParameters['q'],
          'count': 1,
          'items': [
            {'item_name': '검색약정', 'manufacturer': '제조사', 'item_seq': '222'},
          ],
        });
      }
      if (request.url.path.endsWith('/drug-explain/chat')) {
        chatBody = jsonDecode(request.body) as Map<String, dynamic>;
        return jsonResponse({'reply': '두 약을 확인했어요.'});
      }
      throw StateError('unexpected request: ${request.url.path}');
    });

    await tester.pumpWidget(appWith(client));
    await tester.pumpAndSettle();
    await pickSubject(tester, '등록약정');
    await openOtherMedicineSearch(tester);
    await tester.enterText(
      find.byKey(const Key('otherMedicineSearchField')),
      '검색약',
    );
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump();
    await tester.tap(find.text('검색약정'));
    await tester.pumpAndSettle();

    expect(find.text('등록약정 외 1개'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, '같이 먹어도 괜찮나요?'));
    await tester.pumpAndSettle();

    expect(chatBody?['message'], contains('등록약정'));
    expect(chatBody?['message'], contains('검색약정'));
    expect(chatBody?['selected_medicines'], [
      {'medicine_code': '111', 'product_name': '등록약정'},
      {'medicine_code': '222', 'product_name': '검색약정'},
    ]);
    expect(chatBody?['temporary_medicines'], [
      {'medicine_code': '222', 'product_name': '검색약정'},
    ]);
  });

  for (final width in [320.0, 360.0]) {
    testWidgets('좁은 ${width.toInt()}px 화면에서도 빠른 질문과 마지막 답변에 접근한다', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.reset);

      final client = MockClient((request) async {
        if (request.url.path.endsWith('/dashboard')) {
          return jsonResponse({
            'latest_prescription': null,
            'today_medications': [
              {'medicine_code': '197900145', 'product_name': '유한메토트렉세이트정'},
            ],
          });
        }
        if (request.url.path.endsWith('/drug-explain/chat')) {
          return jsonResponse({'reply': '공식 자료에서 확인한 내용을 알려드릴게요.'});
        }
        throw StateError('unexpected request: ${request.url.path}');
      });

      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData.fromView(
            tester.view,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: appWith(client),
        ),
      );
      await tester.pumpAndSettle();
      await pickSubject(tester, '유한메토트렉세이트정');
      expect(tester.takeException(), isNull);

      final first = find.widgetWithText(ChoiceChip, '어디에 쓰는 약인가요?');
      expect(tester.getTopLeft(first).dx, greaterThanOrEqualTo(0));
      final last = find.widgetWithText(ChoiceChip, '임신 중에 조심할 점');
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      expect(tester.getBottomRight(last).dx, lessThanOrEqualTo(width));
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final reply = find.text('공식 자료에서 확인한 내용을 알려드릴게요.');
      await tester.ensureVisible(reply);
      await tester.pumpAndSettle();
      final inputTop = tester.getTopLeft(find.byType(TextField).first).dy;
      expect(tester.getBottomRight(reply).dy, lessThan(inputTop));

      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      await tester.showKeyboard(find.byType(TextField).first);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).first, const Offset(0, -700));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getBottomRight(reply).dy,
        lessThan(tester.getTopLeft(find.byType(TextField).first).dy),
      );
    });
  }

  for (final width in [320.0, 360.0]) {
    testWidgets('AI 답변 표시만 Markdown을 걷어내고 질문과 수치는 보존한다 (${width.toInt()}px)', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.reset);
      const question = '**이 약**을 물어볼게요.';
      const rawReply =
          '## 쉽게 말하면\n> [공식 제품_A정](https://example.test)의 주성분은 __성분_X__예요.\n'
          '1. 만 65세 이상은 확인해 주세요.\n'
          '- 1~2 mg, 0.5 mg, 1일 2회, 5% 이하·10% 초과\n'
          '*확인할 점*은 `공식 자료`에 있어요.\n---\n\n'
          '마지막 문장도 끝까지 읽을 수 있어요.';
      const plainReply =
          '쉽게 말하면\n공식 제품_A정의 주성분은 성분_X예요.\n'
          '• 만 65세 이상은 확인해 주세요.\n'
          '• 1~2 mg, 0.5 mg, 1일 2회, 5% 이하·10% 초과\n'
          '확인할 점은 공식 자료에 있어요.\n\n'
          '마지막 문장도 끝까지 읽을 수 있어요.';
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/dashboard')) {
          return jsonResponse({
            'latest_prescription': null,
            'today_medications': [],
          });
        }
        expect(jsonDecode(request.body)['message'], question);
        return jsonResponse({'reply': rawReply});
      });

      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData.fromView(
            tester.view,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: appWith(client),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), question);
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(ListView).first, const Offset(0, 700));
      await tester.pumpAndSettle();
      expect(find.text(question), findsOneWidget);
      await tester.drag(find.byType(ListView).first, const Offset(0, -700));
      await tester.pumpAndSettle();
      expect(find.text(rawReply), findsNothing);
      expect(find.text(plainReply), findsOneWidget);
      await tester.ensureVisible(find.text(plainReply));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).first, const Offset(0, -700));
      await tester.pumpAndSettle();
      expect(
        tester.getBottomRight(find.text(plainReply)).dy,
        lessThan(tester.getTopLeft(find.byType(TextField)).dy),
      );
    });
  }

  testWidgets('자유 질문 전송에는 explicit intent를 포함하지 않는다', (tester) async {
    Map<String, dynamic>? chatBody;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [],
        });
      }
      chatBody = jsonDecode(request.body) as Map<String, dynamic>;
      return jsonResponse({'reply': '자유 질문 답변'});
    });

    await tester.pumpWidget(appWith(client));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '이 약은 식후에 먹나요?');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();

    expect(chatBody?['message'], '이 약은 식후에 먹나요?');
    expect(chatBody?.containsKey('intent'), isFalse);
    expect(chatBody?.containsKey('selected_medicine'), isFalse);
    expect(chatBody?.containsKey('temporary_medicines'), isFalse);
  });

  testWidgets('첫 화면은 약 전체와 구분된 일반 질문 상태다', (tester) async {
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [
            {'medicine_code': '100', 'product_name': '등록약정'},
          ],
        });
      }
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return jsonResponse({'reply': '일반 안내예요.'});
    });

    await tester.pumpWidget(appWith(client));
    await tester.pumpAndSettle();

    expect(find.text('일반 질문'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    await tester.enterText(find.byType(TextField), '약 복용을 깜빡하면 어떻게 하나요?');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();

    expect(bodies.single['message'], '약 복용을 깜빡하면 어떻게 하나요?');
    expect(bodies.single.containsKey('intent'), isFalse);
    expect(bodies.single.containsKey('selected_medicine'), isFalse);
    expect(bodies.single.containsKey('temporary_medicines'), isFalse);

    await pickSubject(tester, '약 전체');
    expect(find.text('제가 먹는 약 알려주세요'), findsOneWidget);
    await pickSubject(tester, '일반 질문');
    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets('답변 대기 중 쉬운 문구를 표시하고 첫 안내는 선생님 호칭을 사용한다', (tester) async {
    final response = Completer<http.Response>();
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [
            {'product_name': '게보린정'},
          ],
        });
      }
      return response.future;
    });

    await tester.pumpWidget(appWith(client));
    await tester.pumpAndSettle();
    expect(find.textContaining('안녕하세요, 선생님!'), findsOneWidget);

    await pickSubject(tester, '게보린정');
    await tester.ensureVisible(find.text('어디에 쓰는 약인가요?'));
    await tester.tap(find.text('어디에 쓰는 약인가요?'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('답변을 작성하고 있어요'), findsOneWidget);
    expect(find.textContaining('AI가 답변을 작성 중입니다'), findsNothing);
    expect(find.textContaining('AI 약사가 답을 쓰고 있어요'), findsNothing);

    response.complete(jsonResponse({'reply': '확인한 답변이에요.'}));
    await tester.pumpAndSettle();
  });

  testWidgets('약 전체 답변은 확인된 공식 제품명만 굵은 녹색으로 강조한다', (tester) async {
    final originalUserId = MvpSession.userId;
    MvpSession.userId = 'highlight-user';
    addTearDown(() => MvpSession.userId = originalUserId);
    const reply =
        '코다론정은 심장 박동 치료에 쓰며, 유한메토트렉세이트정은 다른 목적으로 사용해요. '
        '코다론정서방정은 확인된 제품명이 아니에요.';
    final teamClient = MockClient((_) async => jsonResponse({'reply': reply}));
    final medicationClient = MockClient(
      (_) async => jsonResponse({
        'medicines': [
          {'medicine_code': '100', 'product_name': '코다론정', 'status': 'active'},
          {
            'medicine_code': '200',
            'official_product_name': '유한메토트렉세이트정',
            'status': 'active',
          },
        ],
      }),
    );

    await tester.pumpWidget(
      appWith(teamClient, medicationClient: medicationClient),
    );
    await tester.pumpAndSettle();
    await pickSubject(tester, '약 전체');
    await tester.tap(find.widgetWithText(ChoiceChip, '제가 먹는 약 알려주세요'));
    await tester.pumpAndSettle();

    final answer = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.textSpan?.toPlainText() == reply,
      ),
    );
    final highlighted = (answer.textSpan! as TextSpan).children!
        .whereType<TextSpan>()
        .where(
          (span) =>
              span.style?.color == AppColors.detailEmphasis &&
              span.style?.fontWeight == FontWeight.w700,
        )
        .map((span) => span.text)
        .toList();
    expect(highlighted, ['코다론정', '유한메토트렉세이트정']);
    expect(highlighted, isNot(contains('코다론정서방정')));
  });

  testWidgets('약 한 가지 답변은 선택한 공식 제품명 한 개만 강조한다', (tester) async {
    const reply = '코다론정은 확인된 약이에요. 유한메토트렉세이트정은 이 질문의 선택 약이 아니에요.';
    final teamClient = MockClient((_) async => jsonResponse({'reply': reply}));
    final medicationClient = MockClient(
      (_) async => jsonResponse({
        'medicines': [
          {'medicine_code': '100', 'product_name': '코다론정', 'status': 'active'},
          {
            'medicine_code': '200',
            'product_name': '유한메토트렉세이트정',
            'status': 'active',
          },
        ],
      }),
    );

    await tester.pumpWidget(
      appWith(teamClient, medicationClient: medicationClient),
    );
    await tester.pumpAndSettle();
    await pickSubject(tester, '코다론정');
    await tester.tap(find.text('이 약은 무슨 약이에요?'));
    await tester.pumpAndSettle();

    final answer = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.textSpan?.toPlainText() == reply,
      ),
    );
    final highlighted = (answer.textSpan! as TextSpan).children!
        .whereType<TextSpan>()
        .where((span) => span.style?.color == AppColors.detailEmphasis)
        .map((span) => span.text)
        .toList();
    expect(highlighted, ['코다론정']);
  });

  testWidgets('서버 fallback 응답을 다른 약의 데모 답변으로 바꾸지 않는다', (tester) async {
    const serverReply = '현재 AI 약사가 설정되지 않아 공식 답변을 생성할 수 없습니다.';
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [],
        });
      }
      return jsonResponse({'reply': serverReply});
    });

    await tester.pumpWidget(appWith(client));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '게보린정의 효능을 알려주세요.');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();

    expect(find.text(serverReply), findsOneWidget);
    expect(find.textContaining('타이레놀정의 주요 효능'), findsNothing);
  });

  testWidgets('검색 약과 기존 복용약의 payload 출처를 구분한다', (tester) async {
    final chatBodies = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [
            {'product_name': '기존약A'},
          ],
        });
      }
      if (request.url.path.endsWith('/drug-explain/chat')) {
        chatBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return jsonResponse({'reply': '답변'});
      }
      final query = request.url.queryParameters['q'];
      return jsonResponse({
        'query': query,
        'count': 1,
        'items': [
          {
            'item_name': query == '검색D' ? '검색약D' : '검색약C',
            'manufacturer': '제조사',
            'item_seq': query == '검색D' ? '4' : '3',
          },
        ],
      });
    });

    await tester.pumpWidget(appWith(client));
    await tester.pumpAndSettle();

    Future<void> selectSearchResult(String query, String result) async {
      await openOtherMedicineSearch(tester);
      await tester.enterText(
        find.byKey(const Key('otherMedicineSearchField')),
        query,
      );
      await tester.pump(const Duration(milliseconds: 550));
      await tester.pump();
      await tester.tap(find.text(result));
      await tester.pumpAndSettle();
    }

    await selectSearchResult('검색C', '검색약C');
    await pickSubject(tester, '기존약A');
    await tester.tap(find.text('어떻게 사용하나요?'));
    await tester.pumpAndSettle();
    expect(chatBodies.last.containsKey('selected_medicine'), isFalse);

    await selectSearchResult('검색D', '검색약D');
    await pickSubject(tester, '검색약D');
    await tester.tap(find.text('어떻게 사용하나요?'));
    await tester.pumpAndSettle();
    expect(chatBodies.last['selected_medicine'], {
      'medicine_code': '4',
      'product_name': '검색약D',
    });

    await pickSubject(tester, '약 전체');
    await tester.tap(find.text('제가 먹는 약 알려주세요'));
    await tester.pumpAndSettle();
    expect(chatBodies.last.containsKey('selected_medicine'), isFalse);
    expect(chatBodies.last['temporary_medicines'], [
      {'medicine_code': '3', 'product_name': '검색약C'},
      {'medicine_code': '4', 'product_name': '검색약D'},
    ]);

    await pickSubject(tester, '검색약D');
    await openOtherMedicineSearch(tester);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('어떻게 사용하나요?'));
    await tester.pumpAndSettle();
    expect(chatBodies.last['selected_medicine'], {
      'medicine_code': '4',
      'product_name': '검색약D',
    });
  });

  testWidgets('약 전체는 전체 복용약용 빠른 질문만 보여 준다', (tester) async {
    var chatCalls = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [],
        });
      }
      chatCalls++;
      return jsonResponse({'reply': '호출되면 안 됨'});
    });

    await tester.pumpWidget(appWith(client));
    await tester.pumpAndSettle();

    expect(find.text('일반 질문'), findsOneWidget);
    expect(find.text('제가 먹는 약 알려주세요'), findsNothing);
    await pickSubject(tester, '약 전체');
    expect(find.text('약 전체'), findsOneWidget);
    expect(find.text('제가 먹는 약 알려주세요'), findsOneWidget);
    expect(find.text('같이 먹어도 괜찮나요?'), findsOneWidget);
    expect(find.text('같은 성분의 약이 있나요?'), findsOneWidget);
    expect(find.text('약마다 주의할 점은요?'), findsOneWidget);
    expect(find.text('이 약은 무슨 약이에요?'), findsNothing);
    expect(find.text('어디에 쓰는 약인가요?'), findsNothing);
    expect(chatCalls, 0);
  });

  testWidgets('약 전체 질문은 current_medicines 없이 전체용 intent와 쉬운 질문을 전송한다', (
    tester,
  ) async {
    final originalUserId = MvpSession.userId;
    MvpSession.userId = 'all-medicines-user';
    addTearDown(() => MvpSession.userId = originalUserId);
    final bodies = <Map<String, dynamic>>[];
    final teamClient = MockClient((request) async {
      expect(request.url.path, '/api/v1/drug-explain/chat');
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return jsonResponse({'reply': '확인된 범위를 알려드릴게요.'});
    });
    final medicationClient = MockClient((request) async {
      expect(request.url.path, '/api/v1/users/all-medicines-user/medicines');
      return jsonResponse({
        'medicines': [
          {
            'medicine_code': '100',
            'official_product_name': 'OCR등록약정',
            'status': 'active',
          },
          {'medicine_code': '200', 'product_name': '손입력약정', 'status': 'active'},
        ],
      });
    });
    await tester.pumpWidget(
      appWith(teamClient, medicationClient: medicationClient),
    );
    await tester.pumpAndSettle();
    await pickSubject(tester, '약 전체');

    const expected = <String, (String, String)>{
      '제가 먹는 약 알려주세요': ('overview', '제가 현재 먹는 약 전체를 쉬운 말로 알려주세요.'),
      '같이 먹어도 괜찮나요?': (
        'combination',
        '제가 현재 먹는 약 전체를 같이 먹을 때 주의할 점이 있는지 확인해 주세요.',
      ),
      '같은 성분의 약이 있나요?': (
        'duplicate',
        '제가 현재 먹는 약 전체에서 같은 성분이나 비슷한 역할이 겹치는 약이 있는지 확인해 주세요.',
      ),
      '약마다 주의할 점은요?': (
        'precautions',
        '제가 현재 먹는 약마다 공식 자료에서 확인되는 주의할 점을 알려주세요.',
      ),
    };
    for (final entry in expected.entries) {
      final chip = find.widgetWithText(ChoiceChip, entry.key);
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(bodies.last['intent'], entry.value.$1);
      expect(bodies.last['message'], entry.value.$2);
      expect(bodies.last.containsKey('selected_medicine'), isFalse);
      expect(bodies.last.containsKey('current_medicines'), isFalse);
      expect(
        find.descendant(
          of: find.byType(ListView).first,
          matching: find.text(entry.key),
        ),
        findsOneWidget,
      );
    }

    await pickSubject(tester, 'OCR등록약정');
    expect(find.text('어디에 쓰는 약인가요?'), findsOneWidget);
    expect(find.text('제가 먹는 약 알려주세요'), findsNothing);
    await pickSubject(tester, '약 전체');
    expect(find.text('제가 먹는 약 알려주세요'), findsOneWidget);
    expect(find.text('어디에 쓰는 약인가요?'), findsNothing);
  });

  for (final width in [320.0, 360.0]) {
    testWidgets('약 전체 빠른 질문은 ${width.toInt()}px 큰 글꼴에서도 가로로 접근한다', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.reset);
      final teamClient = MockClient(
        (_) async => jsonResponse({'reply': '전체 약 답변'}),
      );
      final medicationClient = MockClient(
        (_) async => jsonResponse({
          'medicines': [
            {'medicine_code': '100', 'product_name': '첫째약정'},
            {'medicine_code': '200', 'product_name': '둘째약정'},
          ],
        }),
      );
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData.fromView(
            tester.view,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: appWith(teamClient, medicationClient: medicationClient),
        ),
      );
      await tester.pumpAndSettle();
      await pickSubject(tester, '약 전체');

      final first = find.widgetWithText(ChoiceChip, '제가 먹는 약 알려주세요');
      expect(tester.getTopLeft(first).dx, greaterThanOrEqualTo(0));
      final last = find.widgetWithText(ChoiceChip, '약마다 주의할 점은요?');
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(last).dx, greaterThanOrEqualTo(0));
      expect(tester.getBottomRight(last).dx, lessThanOrEqualTo(width));
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [320.0, 360.0]) {
    testWidgets('긴 약 전체 답변의 처음과 끝은 ${width.toInt()}px 큰 글꼴에서도 스크롤로 접근한다', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.reset);
      final longReply = [
        '긴 답변 시작이에요.',
        ...List.generate(
          18,
          (index) => '등록 약 ${index + 1}의 공식 주의 조건과 확인 범위를 쉬운 말로 안내해요.',
        ),
        '긴 답변 끝이에요.',
      ].join('\n');
      final teamClient = MockClient(
        (_) async => jsonResponse({'reply': longReply}),
      );
      final medicationClient = MockClient(
        (_) async => jsonResponse({
          'medicines': [
            {'medicine_code': '100', 'product_name': '첫째약정'},
            {'medicine_code': '200', 'product_name': '둘째약정'},
          ],
        }),
      );
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData.fromView(
            tester.view,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: appWith(teamClient, medicationClient: medicationClient),
        ),
      );
      await tester.pumpAndSettle();
      await pickSubject(tester, '약 전체');

      final chip = find.widgetWithText(ChoiceChip, '약마다 주의할 점은요?');
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();

      final listFinder = find.byType(ListView).first;
      final list = tester.widget<ListView>(listFinder);
      final controller = list.controller!;
      final listRect = tester.getRect(listFinder);
      final answer = find.text(longReply);
      expect(controller.position.maxScrollExtent, greaterThan(0));

      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      var answerRect = tester.getRect(answer);
      expect(answerRect.bottom, lessThanOrEqualTo(listRect.bottom + 1));
      expect(answerRect.bottom, greaterThan(listRect.top));

      final answerTopOffset =
          (controller.offset + answerRect.top - listRect.top)
              .clamp(0.0, controller.position.maxScrollExtent)
              .toDouble();
      controller.jumpTo(answerTopOffset);
      await tester.pump();
      answerRect = tester.getRect(answer);
      expect(answerRect.top, greaterThanOrEqualTo(listRect.top - 1));
      expect(answerRect.top, lessThan(listRect.bottom));

      final inputRect = tester.getRect(find.byType(TextField));
      expect(listRect.bottom, lessThanOrEqualTo(inputRect.top));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('약 개요 추천 질문은 overview이고 효능 질문은 efficacy를 유지한다', (tester) async {
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [
            {'product_name': '게보린정'},
          ],
        });
      }
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return jsonResponse({'reply': '공식 답변'});
    });

    await tester.pumpWidget(appWith(client));
    await tester.pumpAndSettle();
    await pickSubject(tester, '게보린정');
    await tester.tap(find.text('이 약은 무슨 약이에요?'));
    await tester.pumpAndSettle();
    expect(bodies.last['intent'], 'overview');

    await tester.tap(find.text('어디에 쓰는 약인가요?'));
    await tester.pumpAndSettle();
    expect(bodies.last['intent'], 'efficacy');
  });

  testWidgets('창에서 고른 약 하나만 물어볼 약이 된다', (tester) async {
    final originalUserId = MvpSession.userId;
    MvpSession.userId = 'medicine-toggle-test-user';
    addTearDown(() => MvpSession.userId = originalUserId);

    var chatCalls = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [
            {'product_name': '게보린정'},
            {'product_name': '알마겔정'},
          ],
        });
      }
      chatCalls++;
      return jsonResponse({'reply': '효능 답변'});
    });

    await tester.pumpWidget(appWith(client));
    await tester.pumpAndSettle();

    // 처음에는 특정 약을 고르지 않은 일반 질문 상태다.
    expect(find.text('일반 질문'), findsOneWidget);
    expect(find.text('어디에 쓰는 약인가요?'), findsNothing);

    await pickSubject(tester, '게보린정');
    expect(find.text('게보린정'), findsOneWidget);

    await pickSubject(tester, '알마겔정');
    expect(find.text('알마겔정'), findsOneWidget);
    expect(find.text('게보린정'), findsNothing);

    await pickSubject(tester, '약 전체');
    expect(find.text('어디에 쓰는 약인가요?'), findsNothing);
    expect(chatCalls, 0);

    await pickSubject(tester, '게보린정');
    await tester.tap(find.text('어디에 쓰는 약인가요?'));
    await tester.pumpAndSettle();
    expect(chatCalls, 1);
    expect(find.text('효능 답변'), findsOneWidget);
  });

  testWidgets('빠른 질문 로딩 중 중복 요청을 막고 자유 질문 전송은 유지한다', (tester) async {
    final originalUserId = MvpSession.userId;
    MvpSession.userId = 'quick-question-test-user';
    addTearDown(() => MvpSession.userId = originalUserId);

    final firstReply = Completer<http.Response>();
    final sentMessages = <String>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [
            {'product_name': '게보린정'},
          ],
        });
      }
      sentMessages.add(
        (jsonDecode(request.body) as Map<String, dynamic>)['message'] as String,
      );
      if (sentMessages.length == 1) return firstReply.future;
      return jsonResponse({'reply': '자유 질문 답변'});
    });

    await tester.pumpWidget(appWith(client));
    await tester.pumpAndSettle();
    await pickSubject(tester, '게보린정');
    await tester.ensureVisible(
      find.widgetWithText(ChoiceChip, '사용 뒤 증상이 생기면?'),
    );
    await tester.tap(find.text('사용 뒤 증상이 생기면?'));
    await tester.pump();
    await tester.tap(find.text('어떻게 사용하나요?'), warnIfMissed: false);
    await tester.pump();
    expect(sentMessages, ['이 약을 사용한 뒤 평소와 다른 증상이 생기면 어떻게 해야 하나요?']);

    firstReply.complete(jsonResponse({'reply': '부작용 답변'}));
    await tester.pumpAndSettle();
    final chatField = find.byType(TextField);
    await tester.enterText(chatField, '이 약은 식후에 먹어도 되나요?');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();

    expect(sentMessages.last, '이 약은 식후에 먹어도 되나요?');
    expect(find.text('자유 질문 답변'), findsOneWidget);
  });

  testWidgets('검색 결과 없음과 네트워크 오류를 안전한 문구로 표시한다', (tester) async {
    var failSearch = false;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [],
        });
      }
      if (failSearch) throw http.ClientException('private network detail');
      return jsonResponse({'query': '없음', 'count': 0, 'items': []});
    });

    await tester.pumpWidget(appWith(client));
    await tester.pump();
    await openOtherMedicineSearch(tester);
    final field = find.byKey(const Key('otherMedicineSearchField'));

    await tester.enterText(field, '없음');
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump();
    expect(find.text('검색된 공식 의약품이 없습니다.'), findsOneWidget);

    failSearch = true;
    await tester.enterText(field, '오류');
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump();
    expect(find.text('네트워크 연결을 확인한 후 다시 시도해주세요.'), findsOneWidget);
    expect(find.textContaining('private network detail'), findsNothing);
  });

  testWidgets('AI 답변 오류는 HTTP 상태와 내부 예외 대신 쉬운 안내를 표시한다', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [],
        });
      }
      return jsonResponse({
        'detail': 'SocketException https://private.example/api',
      }, statusCode: 500);
    });

    await tester.pumpWidget(appWith(client));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '이 약을 알려주세요.');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();

    expect(
      find.text(
        '지금은 답변을 불러오지 못했어요.\n'
        '잠시 후 다시 시도해 주세요.\n'
        '약의 사용 방법을 임의로 바꾸지는 마세요.',
      ),
      findsOneWidget,
    );
    for (final internal in ['HTTP 500', 'SocketException', 'private.example']) {
      expect(find.textContaining(internal), findsNothing);
    }
  });

  testWidgets('동일 검색어의 진행 중 요청과 직전 성공 요청을 중복 전송하지 않는다', (tester) async {
    var searchCalls = 0;
    final pending = Completer<http.Response>();
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [],
        });
      }
      searchCalls++;
      return pending.future;
    });

    await tester.pumpWidget(appWith(client));
    await tester.pump();
    await openOtherMedicineSearch(tester);
    final field = find.byKey(const Key('otherMedicineSearchField'));

    await tester.enterText(field, '게보');
    await tester.pump(const Duration(milliseconds: 550));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(searchCalls, 1);

    pending.complete(
      jsonResponse({
        'query': '게보',
        'count': 1,
        'items': [
          {'item_name': '게보린정', 'manufacturer': '삼진제약', 'item_seq': '1'},
        ],
      }),
    );
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(searchCalls, 1);
  });

  testWidgets('검색 실패 후에는 같은 검색어를 다시 요청할 수 있다', (tester) async {
    var searchCalls = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [],
        });
      }
      searchCalls++;
      if (searchCalls == 1) throw http.ClientException('temporary failure');
      return jsonResponse({
        'query': '게보',
        'count': 1,
        'items': [
          {'item_name': '게보린정', 'manufacturer': '삼진제약', 'item_seq': '1'},
        ],
      });
    });

    await tester.pumpWidget(appWith(client));
    await tester.pump();
    await openOtherMedicineSearch(tester);
    final field = find.byKey(const Key('otherMedicineSearchField'));

    await tester.enterText(field, '게보');
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump();
    expect(searchCalls, 1);
    expect(find.text('네트워크 연결을 확인한 후 다시 시도해주세요.'), findsOneWidget);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(searchCalls, 2);
    expect(find.text('게보린정'), findsOneWidget);
  });

  testWidgets('일반 질문의 약 이름 후속 입력은 앞 질문과 연결해 전송한다', (tester) async {
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dashboard')) {
        return jsonResponse({
          'latest_prescription': null,
          'today_medications': [],
        });
      }
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return jsonResponse({
        'reply': bodies.length == 1
            ? '커피는 약에 따라 효과나 부작용에 영향을 줄 수 있어요. 정확한 확인을 위해 드시는 약 이름을 알려주세요.'
            : '확인한 공식정보로 답했어요.',
      });
    });

    await tester.pumpWidget(appWith(client));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '약 먹고 커피랑 마셔도 괜찮아?');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '환인아캄프로세이트정');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();

    expect(bodies.first['message'], '약 먹고 커피랑 마셔도 괜찮아?');
    expect(find.textContaining('커피는 약에 따라'), findsOneWidget);
    expect(
      bodies.last['message'],
      '환인아캄프로세이트정에 대해 다음 질문에 답해 주세요: 약 먹고 커피랑 마셔도 괜찮아?',
    );
    expect(find.text('환인아캄프로세이트정'), findsOneWidget);
    expect(find.textContaining('다음 질문에 답해 주세요'), findsNothing);
    expect(bodies.last.containsKey('selected_medicine'), isFalse);
  });
}
