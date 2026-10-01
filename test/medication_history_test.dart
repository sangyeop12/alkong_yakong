import 'package:alkong_yakong/core/session/mvp_session.dart';
import 'package:alkong_yakong/core/theme/app_theme.dart';
import 'package:alkong_yakong/features/dashboard/application/medication_history_provider.dart';
import 'package:alkong_yakong/features/dashboard/presentation/screens/medication_record_screen.dart';
import 'package:alkong_yakong/features/medication/application/medication_controller.dart';
import 'package:alkong_yakong/features/medication/domain/medication_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    MvpSession.latestScheduleDates = <String>{};
  });

  test('OCR 캐시는 앞으로의 약 있는 날만 켜고 먹었어요로 치지 않는다', () {
    final today = dateOnly(DateTime.now());
    final tomorrow = today.add(const Duration(days: 1));
    final yesterday = today.subtract(const Duration(days: 1));
    String key(DateTime day) =>
        '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';

    MvpSession.latestScheduleDates = {key(yesterday), key(tomorrow)};
    final merged = mergeCachedScheduleDates(const {});

    expect(merged.containsKey(yesterday), isFalse);
    expect(merged[tomorrow]?.total, 1);
    expect(merged[tomorrow]?.taken, 0);
  });

  test('서버에 이미 있는 날의 횟수는 캐시가 덮지 않는다', () {
    final tomorrow = dateOnly(DateTime.now()).add(const Duration(days: 1));
    String key(DateTime day) =>
        '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
    MvpSession.latestScheduleDates = {key(tomorrow)};
    final merged = mergeCachedScheduleDates({
      tomorrow: DayAdherence(date: tomorrow, taken: 0, total: 3),
    });
    expect(merged[tomorrow]?.total, 3);
  });

  testWidgets('기록 이번 주에 OCR 날짜가 약 있는 날로 보인다', (tester) async {
    final today = dateOnly(DateTime.now());
    if (today.weekday == DateTime.sunday) {
      return;
    }
    final upcoming = today.add(const Duration(days: 1));
    String key(DateTime day) =>
        '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
    MvpSession.latestScheduleDates = {key(upcoming)};

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          medicationProvider.overrideWith(_EmptyMedication.new),
          medicationHistoryProvider.overrideWith(
            (ref) async => const <DateTime, DayAdherence>{},
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.build(),
          home: Scaffold(body: MedicationRecordScreen(onBackToToday: _noop)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // "약 있는 날" 표시는 없앴다. 아직 안 드신 날을 따로 칠하면 다 드신
    // 날과 헷갈린다 — 앞날은 아직 오지 않은 날로만 둔다.
    expect(find.bySemanticsLabel(RegExp(r'약 있는 날')), findsNothing);
    expect(
      find.bySemanticsLabel(RegExp(r'일 .*요일, 아직 오지 않은 날')),
      findsWidgets,
    );
  });
}

void _noop() {}

class _EmptyMedication extends MedicationController {
  @override
  TodayMedication build() => const TodayMedication(
    doses: [],
    guardianRelation: '보호자',
    guardianName: '가족',
  );
}
