import 'package:alkong_yakong/core/constants/app_colors.dart';
import 'package:alkong_yakong/core/widgets/senior_card.dart';
import 'package:alkong_yakong/features/medicines/application/user_medicines_controller.dart';
import 'package:alkong_yakong/features/medicines/domain/display_policy.dart';
import 'package:alkong_yakong/features/medicines/domain/user_medicine_models.dart';
import 'package:alkong_yakong/features/medicines/presentation/screens/drug_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> data() => {
  'medicine_code': 'synthetic',
  'product_name': '합성 제품',
  'detail_status': 'READY',
  'ingredient_explanation': '정해진 작용을 돕는 성분이에요.',
  'approved_use_summary': '기존 사용 목적',
  'approved_uses': ['기존 조건'],
};

class FakeDetails extends UserMedicinesController {
  final UserMedicine medicine;
  FakeDetails(this.medicine);
  @override
  Future<List<UserMedicine>> build() async => [];
  @override
  Future<UserMedicine> loadDetail(String code) async => medicine;
}

void main() {
  testWidgets(
    'existing SeniorCard ExpansionTile emits Flutter SDK ink warning',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SeniorCard(
              child: ExpansionTile(title: Text('기존 펼침 카드'), children: []),
            ),
          ),
        ),
      );
      final error = tester.takeException();
      expect(error, isA<FlutterError>());
      expect(
        error.toString(),
        startsWith(
          'ListTile background color or ink splashes may be invisible.',
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );
  test('missing and malformed new fields have safe defaults', () {
    for (final raw in [
      null,
      12,
      'bad',
      {},
      [
        null,
        3,
        {'title': ''},
      ],
    ]) {
      final med = UserMedicine.fromJson({
        ...data(),
        'ingredient_highlight': 12,
        'treatment_uses': raw,
      });
      expect(med.ingredientHighlight, isEmpty);
      expect(med.treatmentUses, isEmpty);
      expect(med.approvedUseSummary, '기존 사용 목적');
    }
    expect(UserMedicine.fromJson(data()).treatmentUses, isEmpty);
  });

  test('treatment list is capped at three', () {
    final med = UserMedicine.fromJson({
      ...data(),
      'treatment_uses': List.generate(
        5,
        (i) => {'title': '목적 $i', 'description': '조건 $i'},
      ),
    });
    expect(med.treatmentUses.length, 3);
  });

  test(
    'official usage regex executes and preserves numbers conditions routes',
    () {
      const source =
          '1.\n성인 : 1회 0.5 mL를 1일 2회 7일간 바른다. 12세 미만에는 사용하지 않는다. 신기능 저하 환자 : 주사하지 않는다.';
      final result = formatOfficialUsage(source);
      expect(
        result.replaceAll(RegExp(r'\s'), ''),
        source.replaceAll(RegExp(r'\s'), ''),
      );
      expect(result, contains('1. 성인'));
    },
  );

  Future<void> show(
    WidgetTester tester,
    Map<String, dynamic> raw, {
    double scale = 1,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final medicine = UserMedicine.fromJson(raw);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userMedicinesProvider.overrideWith(() => FakeDetails(medicine)),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const DrugDetailScreen(medicineCode: 'synthetic'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final error = tester.takeException();
    if (raw['official_usage'] != null ||
        (raw['detail_status'] != 'OUTDATED' &&
            raw['all_approved_uses'] is List &&
            (raw['all_approved_uses'] as List).isNotEmpty)) {
      // Same diagnostic reproduced above with the unchanged shared widget.
      expect(error, isA<FlutterError>());
      expect(
        error.toString(),
        startsWith(
          'ListTile background color or ink splashes may be invisible.',
        ),
      );
      expect(tester.takeException(), isNull);
    } else {
      expect(error, isNull);
    }
  }

  testWidgets('old backend keeps original purpose display', (tester) async {
    await show(tester, data());
    expect(find.text('기존 사용 목적'), findsOneWidget);
    expect(find.text('· 기존 조건'), findsOneWidget);
    expect(find.text('정해진 작용을 돕는 성분이에요.'), findsOneWidget);
  });

  testWidgets('long explanation remains complete with large text', (
    tester,
  ) async {
    final body = List.filled(15, '성분의 확인된 설명을 그대로 표시해요.').join(' ');
    await show(tester, {...data(), 'ingredient_explanation': body}, scale: 2);
    final text = tester.widget<Text>(find.text(body));
    expect(text.maxLines, isNull);
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    expect(text.data, body);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'missing explanation hides ingredient card without empty-state copy',
    (tester) async {
      await show(tester, {...data(), 'ingredient_explanation': ''});
      expect(
        find.text('주성분의 쉬운 설명을 아직 확인하지 못했어요. 공식 정보가 없다는 뜻은 아니에요.'),
        findsNothing,
      );
      expect(find.text('주성분 설명을 불러오지 못했어요. 잠시 후 다시 확인해 주세요.'), findsNothing);
      expect(find.text('기존 사용 목적'), findsOneWidget);
    },
  );

  testWidgets('matched phrase alone is bold green and purposes displayed', (
    tester,
  ) async {
    await show(tester, {
      ...data(),
      'ingredient_highlight': '정해진 작용',
      'treatment_uses': [
        {'title': '치통', 'description': '성인에만 사용한다.'},
      ],
    });
    final text = tester
        .widgetList<Text>(find.byType(Text))
        .firstWhere((t) => t.textSpan?.toPlainText() == '정해진 작용을 돕는 성분이에요.');
    final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
    final highlighted = spans.singleWhere((s) => s.text == '정해진 작용');
    expect(highlighted.style!.color, AppColors.detailEmphasis);
    expect(highlighted.style!.fontWeight, FontWeight.w800);
    expect(find.text('성인에만 사용한다.'), findsOneWidget);
    final title = tester.widget<Text>(find.text('· 치통'));
    expect(title.style!.color, AppColors.detailEmphasis);
    expect(title.style!.fontWeight, FontWeight.w800);
    final description = tester.widget<Text>(find.text('성인에만 사용한다.'));
    expect(description.style!.color, isNot(AppColors.detailEmphasis));
  });

  testWidgets(
    'whole body, outer-space match and blank highlight stay ordinary',
    (tester) async {
      const body = '  정해진 작용을 돕는 성분이에요.  ';
      for (final highlight in [
        body,
        body.trim(),
        ' ${body.trim()} ',
        '',
        '없는 구절',
      ]) {
        await tester.pumpWidget(const SizedBox.shrink());
        await show(tester, {
          ...data(),
          'ingredient_explanation': body,
          'ingredient_highlight': highlight,
        });
        final text = tester.widget<Text>(find.text(body));
        expect(text.textSpan, isNull);
        expect(text.data, body);
        expect(text.style!.color, isNot(AppColors.detailEmphasis));
      }
    },
  );

  testWidgets(
    'only first repeated phrase highlighted and complete body preserved',
    (tester) async {
      const body = '작용을 돕고, 다시 작용을 돕는 설명이에요.';
      await show(tester, {
        ...data(),
        'ingredient_explanation': body,
        'ingredient_highlight': '작용을 돕',
      });
      final text = tester
          .widgetList<Text>(find.byType(Text))
          .firstWhere((t) => t.textSpan?.toPlainText() == body);
      final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
      expect(
        spans.where((s) => s.style?.color == AppColors.detailEmphasis).length,
        1,
      );
      expect(text.textSpan!.toPlainText(), body);
      expect(spans.last.text, contains('다시 작용을 돕'));
    },
  );

  testWidgets(
    'full expansion retains representative and distinct conditions, removes exact duplicates',
    (tester) async {
      const entries = [
        '기존 조건',
        '성인에게 1~2 mg을 사용한다.',
        '성인에게 12 mg을 사용한다.',
        '12세 이상만 사용한다.',
        '12세 이상만 사용한다. 단, 예외 대상은 제외한다.',
      ];
      await show(tester, {
        ...data(),
        'all_approved_uses': [...entries, entries[1]],
        'treatment_uses': [
          {'title': '치통', 'description': entries[1]},
        ],
      });
      final previous = FlutterError.onError;
      final knownWarnings = <String>[];
      FlutterError.onError = (details) {
        if (details.exceptionAsString().startsWith(
          'ListTile background color or ink splashes may be invisible.',
        )) {
          knownWarnings.add(details.exceptionAsString());
        } else {
          previous?.call(details);
        }
      };
      try {
        await tester.tap(find.text('전체 허가 목적'));
        await tester.pumpAndSettle();
        expect(knownWarnings, isNotEmpty);
        expect(find.text('· ${entries[0]}'), findsNothing);
        for (final entry in entries.skip(1)) {
          expect(find.text('· $entry'), findsOneWidget);
        }
        expect(
          find.text(entries[1]),
          findsOneWidget,
        ); // Representative remains too.
        final expanded = tester.widget<ExpansionTile>(
          find.byType(ExpansionTile),
        );
        final texts = expanded.children
            .whereType<Align>()
            .map((a) => (a.child! as Text).data)
            .toList();
        expect(texts, entries.skip(1).map((e) => '· $e').toList());
      } finally {
        FlutterError.onError = previous;
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('nonmatching highlight uses ordinary text', (tester) async {
    await show(tester, {...data(), 'ingredient_highlight': '없는 구절'});
    final text = tester.widget<Text>(find.text('정해진 작용을 돕는 성분이에요.'));
    expect(text.textSpan, isNull);
  });

  test('title-only treatment uses are kept', () {
    final med = UserMedicine.fromJson({
      ...data(),
      'treatment_uses': [
        {'title': '속쓰림·위 불편감', 'description': ''},
      ],
    });
    expect(med.treatmentUses.single.title, '속쓰림·위 불편감');
    expect(med.treatmentUses.single.description, isEmpty);
    expect(med.hasDetailContent, isTrue);
  });
}
