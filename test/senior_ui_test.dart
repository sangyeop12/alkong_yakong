import 'dart:io';
import 'package:alkong_yakong/core/theme/app_theme.dart';
import 'package:alkong_yakong/features/auth/presentation/screens/login_screen.dart';
import 'package:alkong_yakong/features/auth/domain/exclusive_choice.dart';
import 'package:alkong_yakong/features/medicines/presentation/screens/my_medicines_screen.dart';
import 'package:alkong_yakong/features/biosignal/application/heart_sensor.dart';
import 'package:alkong_yakong/features/biosignal/domain/heart_data.dart';
import 'package:alkong_yakong/features/biosignal/presentation/screens/measure_screen.dart';
import 'package:alkong_yakong/features/biosignal/presentation/screens/polar_screen.dart';
import 'package:alkong_yakong/features/auth/presentation/screens/signup_screen.dart';
import 'package:alkong_yakong/features/dashboard/presentation/screens/guardian_home_screen.dart';
import 'package:alkong_yakong/features/dashboard/presentation/screens/medication_record_screen.dart';
import 'package:alkong_yakong/features/dashboard/presentation/screens/month_calendar_screen.dart';
import 'package:alkong_yakong/features/dashboard/presentation/screens/patient_home_screen.dart';
import 'package:alkong_yakong/features/medication/domain/medication_models.dart';
import 'package:alkong_yakong/features/medication/application/medication_controller.dart';
import 'package:alkong_yakong/core/network/api_client.dart';
import 'package:alkong_yakong/features/onboarding/presentation/screens/first_run_screen.dart';
import 'package:alkong_yakong/features/profile/presentation/screens/mypage_screen.dart';
import 'package:alkong_yakong/features/reminder/domain/reminder_ladder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:alkong_yakong/core/widgets/senior_card.dart';
import 'package:alkong_yakong/features/dashboard/presentation/screens/home_screen.dart';
import 'package:alkong_yakong/features/easy_flow/domain/easy_flow.dart';
import 'package:alkong_yakong/core/widgets/senior_bottom_nav.dart';
import 'package:alkong_yakong/core/widgets/senior_header.dart';
import 'package:alkong_yakong/core/widgets/senior_timeline.dart';
import 'package:alkong_yakong/core/mode/app_mode.dart';
import 'package:alkong_yakong/features/medication/presentation/screens/dose_done_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:alkong_yakong/features/biosignal/data/heart_repository.dart';
import 'package:alkong_yakong/features/biosignal/presentation/screens/heart_screen.dart';

/// 서버 대신 정해 둔 기록을 돌려준다. null이면 "못 읽음"이다.
class _FakeHeartRepository extends HeartRepository {
  _FakeHeartRepository(this.result);
  HeartData? result;
  String? lastUserId;

  @override
  Future<HeartData?> fetch({String? userId}) async {
    lastUserId = userId;
    return result;
  }
}

/// 붙어 있다고만 말하고 배터리·측정값은 아직 안 준 센서.
class _StreamingSensor extends HeartSensor {
  @override
  HeartSensorStatus get status => HeartSensorStatus.streaming;
}

/// 테스트에서만 쓰는 채워진 기록. 앱 코드에는 이런 값을 두지 않는다.
const _heartSample = HeartData(
  today: HeartPair(before: 78, after: 72),
  todaySlotLabel: '저녁 약',
  beforeAt: '오후 5시 52분',
  afterAt: '오후 6시 40분',
  week: [
    HeartDay('월', HeartPair(before: 80, after: 74)),
    HeartDay('화', HeartPair()),
  ],
  month: [
    HeartMonthDay(1, HeartPair(before: 79, after: 73)),
    HeartMonthDay(2, HeartPair()),
  ],
  streakDays: 1,
  bestStreakDays: 1,
  anomaly: null,
  sensorConnected: false,
  sensorBattery: null,
  sensorLastReadAt: '',
  notifyGuardian: true,
);

/// 읽기는 됐지만 잰 값이 하나도 없는 기록.
const _heartEmpty = HeartData(
  today: HeartPair(),
  todaySlotLabel: '',
  beforeAt: '',
  afterAt: '',
  week: [HeartDay('월', HeartPair())],
  month: [HeartMonthDay(1, HeartPair())],
  streakDays: 0,
  bestStreakDays: 0,
  anomaly: null,
  sensorConnected: false,
  sensorBattery: null,
  sensorLastReadAt: '',
  notifyGuardian: true,
);

/// 시니어 리디자인의 QA 기준을 코드로 굳힌 테스트.
///
/// 특히 5h — 시스템 글자 크기를 최대로 올렸을 때도 레이아웃이 버텨야 한다.
/// 어떤 화면도 오버플로로 터지면 안 된다.
void main() {
  _forbiddenFeatureTests();
  _easyModeTests();
  _signupTests();
  _sensorTests();
  _shippingTests();
  _backButtonTests();
  _homeTimelineTests();
  _recordTimelineTests();
  _rightAlignTests();
  _medicinesByTimeTests();
  _confirmPreviewTests();
  _screenCopyTests();
  _colorTokenTests();
  _realLoginTests();
  _calendarTests();
  Widget wrap(Widget child, {double textScale = 1.0}) {
    return ProviderScope(
      overrides: [
        medicationProvider.overrideWith(_SeniorTestMedicationController.new),
      ],
      child: MaterialApp(
        theme: AppTheme.build(),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(body: child),
        ),
      ),
    );
  }

  final screens = <String, Widget Function()>{
    '오늘 홈 (3a)': () => const PatientHomeScreen(),
    '기록 (4c)': () => const MedicationRecordScreen(),
    '내 정보 (4h)': () => const MyPageScreen(),
    '로그인 (4i)': () => const LoginScreen(),
    '첫 사용 (5g)': () => const FirstRunScreen(),
    '보호자 (4j·4k)': () => const GuardianHomeScreen(),
  };

  /// 시중 전화기 크기 × 글자 배율. **가장 작은 화면에서 글자를 키운 조합**이
  /// 가장 험하다 — 어르신은 글자를 키워 쓰시니 거기서 버텨야 한다.
  /// 2.0x는 iOS·안드로이드의 접근성 최대 배율 언저리다.
  const sizes = <String, Size>{
    '작은 폰 320x568': Size(320, 568),
    '보급형 폰 360x640': Size(360, 640),
    '보통 폰 390x844': Size(390, 844),
    '큰 폰 430x932': Size(430, 932),
  };

  sizes.forEach((sizeName, size) {
    for (final scale in <double>[1.0, 2.0]) {
      group('$sizeName · 글자 배율 ${scale}x에서 그려진다', () {
        screens.forEach((name, build) {
          testWidgets(name, (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            addTearDown(tester.view.reset);

            await tester.pumpWidget(wrap(build(), textScale: scale));
            await tester.pump();
            expect(tester.takeException(), isNull);
          });
        });
      });
    }
  });

  testWidgets('먹었어요는 바로 기록하지 않고 센서 착용부터 묻는다 (13)', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const PatientHomeScreen()));
    await tester.pump();

    expect(find.text('먹었어요'), findsOneWidget);
    await tester.tap(find.text('먹었어요'));
    await tester.pumpAndSettle();
    // 기록보다 시트가 먼저다. 띠를 차고 계시면 심박수를 잴 기회이기 때문이다.
    expect(find.textContaining('심박 센서를'), findsOneWidget);
    expect(find.text('차고 있어요 · 측정'), findsOneWidget);
    expect(find.text('안 차고 있어요 · 복약만 기록'), findsOneWidget);
    expect(find.text('그만두기'), findsOneWidget);
  });

  testWidgets('그만두기를 고르면 아무것도 기록되지 않는다 (13)', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var done = 0;
    await tester.pumpWidget(wrap(PatientHomeScreen(onDone: (_) => done++)));
    await tester.pump();

    await tester.tap(find.text('먹었어요'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('그만두기'));
    await tester.pumpAndSettle();

    expect(done, 0);
    expect(find.text('먹었어요'), findsOneWidget);
  });

  testWidgets('복약만 기록을 고르면 완료로 넘어간다 (14)', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var done = 0;
    await tester.pumpWidget(wrap(PatientHomeScreen(onDone: (_) => done++)));
    await tester.pump();

    await tester.tap(find.text('먹었어요'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('안 차고 있어요 · 복약만 기록'));
    await tester.pumpAndSettle();
    if (find.text('그래도 먹었어요').evaluate().isNotEmpty) {
      await tester.tap(find.text('그래도 먹었어요'));
      await tester.pumpAndSettle();
    }

    expect(done, 1);
  });

  testWidgets('완료 화면의 되돌리기는 시간 제한 없이 있다 (14)', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const DoseDoneScreen(slot: DoseSlot.morning)));
    await tester.pump();

    // 남은 약이 있으면 그 약을 먼저 보여 준다. 되돌리는 길은 그래도 남는다.
    expect(find.text('잘못 눌렀어요 · 되돌리기'), findsOneWidget);
  });

  test('재알림 사다리는 0·15·45분 뒤 어르신, 60분 뒤 보호자다 (5c)', () {
    final doseTime = DateTime(2026, 8, 20, 18);
    final plan = ReminderLadder.planFor(DoseSlot.dinner, doseTime);

    expect(plan.length, 4);
    expect(plan[0].fireAt, doseTime);
    expect(plan[1].fireAt, doseTime.add(const Duration(minutes: 15)));
    expect(plan[2].fireAt, doseTime.add(const Duration(minutes: 45)));
    expect(plan[3].fireAt, doseTime.add(const Duration(minutes: 60)));

    expect(plan[0].message, '저녁 약 드실 시간이에요');
    expect(plan[1].message, '아직 저녁 약을 안 드셨어요');
    expect(plan[2].message, '저녁 약을 꼭 드셔야 해요');

    // 보호자 통보만 보호자에게 간다.
    expect(plan.where((r) => r.toGuardian).length, 1);
  });

  test('30분 뒤에 다시를 고르면 사다리 전체가 30분 밀린다 (5c)', () {
    final doseTime = DateTime(2026, 8, 20, 18);
    final plan = ReminderLadder.planFor(
      DoseSlot.dinner,
      doseTime,
      snoozeCount: 1,
    );

    // 단계를 건너뛰지 않고 전부 30분씩 밀린다.
    expect(plan[0].fireAt, doseTime.add(const Duration(minutes: 30)));
    expect(plan[3].fireAt, doseTime.add(const Duration(minutes: 90)));
  });

  test('절대시간으로 말한다 — 상대시간은 보조다', () {
    expect(DoseSlot.absoluteTime(DateTime(2026, 8, 20, 18, 2)), '오후 6시 2분');
    expect(DoseSlot.dinner.spokenTime, '저녁 6시');
  });

  testWidgets('비밀번호 "보기"는 입력칸 오른쪽 끝에 붙는다 (4i)', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const LoginScreen()));
    await tester.pump();

    // 입력칸은 화면 좌우 여백 24를 뺀 폭을 쓴다.
    const fieldRight = 390.0 - 24.0;
    final buttonRight = tester.getBottomRight(find.text('보기')).dx;

    // 글자 끝에서 테두리까지 20px 안쪽 — 가로를 채우는 버튼이면 훨씬 멀어진다.
    expect(fieldRight - buttonRight, lessThan(24));
  });
}

// ════════════════════════════════════════════════════════════════
//  쉬운 모드 — 화면은 그대로, 오가는 방법만 다르다
// ════════════════════════════════════════════════════════════════

void _easyModeTests() {
  testWidgets('쉬운 모드는 탭 대신 "다음 한 걸음" 버튼 하나를 쓴다 (40)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appModeProvider.overrideWith((ref) => _EasyMode())],
        child: MaterialApp(theme: AppTheme.build(), home: const HomeScreen()),
      ),
    );
    await tester.pump();

    expect(find.byType(SeniorBottomNav), findsNothing);
    expect(find.text(kEasyFlow.first.nextLabel), findsOneWidget);
    // 아바타 자리가 메뉴 버튼으로 바뀐다.
    expect(find.text('메뉴'), findsOneWidget);
    // 모드 배지는 파랑으로 차 있다.
    expect(find.text('쉬운 화면'), findsOneWidget);
  });

  testWidgets('약을 안 눌렀는데 넘어가려 하면 한 번 묻는다 (42)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appModeProvider.overrideWith((ref) => _EasyMode()),
          medicationProvider.overrideWith(_SeniorTestMedicationController.new),
        ],
        child: MaterialApp(theme: AppTheme.build(), home: const HomeScreen()),
      ),
    );
    await tester.pump();

    await tester.tap(find.text(kEasyFlow.first.nextLabel));
    await tester.pumpAndSettle();

    // 자동으로 "안 드셨어요"로 확정하지 않는다.
    expect(find.textContaining('아직 안 누르셨어요'), findsOneWidget);
    expect(find.text('먹었어요 · 다음으로'), findsOneWidget);
    expect(find.text('그냥 넘어갈게요'), findsOneWidget);
    expect(find.text('이 화면에 그대로 있기'), findsOneWidget);
  });

  test('쉬운 모드가 부르는 화면은 모두 일반 모드에도 있는 화면이다', () {
    for (final step in kEasyFlow) {
      expect(EasyScreen.values.contains(step.screen), isTrue);
    }
    final screens = kEasyFlow.map((s) => s.screen).toList();
    expect(screens.toSet().length, screens.length);
  });

  test('모든 단계에 다음 버튼 라벨이 있다', () {
    for (final step in kEasyFlow) {
      expect(step.nextLabel.trim(), isNotEmpty);
    }
  });

  test('측정 중에는 하단 바를 숨긴다', () {
    // 자기 흐름을 끝까지 마쳐야 하는 화면에서는 "다음"이 방해가 된다.
    expect(showsEasyBar(EasyScreen.measure), isFalse);
    expect(showsEasyBar(EasyScreen.today), isTrue);
  });

  test('메뉴에서 갈 수 있는 곳이 흐름보다 넓다', () {
    // 한 줄로만 갈 수 있으면 그것대로 갇힌다.
    expect(kEasyMenu.length, greaterThan(kEasyFlow.length));
  });
}

/// 테스트에서 쉬운 모드로 고정하기 위한 알림자.
class _EasyMode extends AppModeNotifier {
  _EasyMode() {
    state = AppMode.easy;
  }
}

// ════════════════════════════════════════════════════════════════
//  핸드오프가 금지한 것들 — 되살아나면 여기서 걸린다
// ════════════════════════════════════════════════════════════════

void _forbiddenFeatureTests() {
  final libDir = Directory('lib');

  List<File> dartFiles() => libDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  test('음성으로 복약을 기록하는 화면이 없다', () {
    final voiceDir = Directory('lib/features/voice');
    expect(voiceDir.existsSync(), isFalse, reason: '음성 기능은 제거 대상이다');

    // 낡은 심박 화면은 배선을 HeartSensor로 옮긴 뒤 지웠다.
    // 배선이 남아 있는지는 test_heartbeat_wiring.py 가 지킨다.
    expect(
      File(
        'lib/features/biosignal/presentation/screens/heartbeat_screen.dart',
      ).existsSync(),
      isFalse,
    );

    for (final file in dartFiles()) {
      final text = file.readAsStringSync();
      expect(text.contains('VoiceScreen'), isFalse, reason: file.path);
      expect(text.contains("'/voice'"), isFalse, reason: file.path);
    }
  });

  test('어르신 화면에 전화 거는 버튼이 없다', () {
    // 보호자 화면의 "전화 드리기"는 방향이 반대라 허용된다.
    const guardianOnly = 'guardian_home_screen.dart';
    for (final file in dartFiles()) {
      if (file.path.endsWith(guardianOnly)) continue;
      final text = file.readAsStringSync();
      for (final banned in ["label: '약국에 전화하기'", "전화를 겁니다"]) {
        expect(
          text.contains(banned),
          isFalse,
          reason: '${file.path}에 "$banned"가 남아 있다',
        );
      }
    }
  });

  test('보호자 연락은 스낵바로 알린다', () {
    final dur = File(
      'lib/features/dur_analysis/presentation/screens/dur_analysis_screen.dart',
    ).readAsStringSync();
    expect(dur.contains('showSeniorSnackbar'), isTrue);
  });

  test('알림은 시니어 스낵바 하나로만 띄운다', () {
    // 오류를 화면 안에 끼워 넣으면 버튼이 밀려 내려가고, 누르려던 자리에
    // 글자가 붙는다. 기본 스낵바는 모양이 따로 놀아 같은 말을 두 가지로 한다.
    for (final file in dartFiles()) {
      final path = file.path.replaceAll(r'\', '/');
      if (path.endsWith('core/widgets/senior_feedback.dart')) continue;
      final text = file.readAsStringSync();
      expect(
        text.contains('showSnackBar('),
        isFalse,
        reason: '$path 에 기본 스낵바가 있다 — showSeniorSnackbar를 쓴다',
      );
      if (!path.endsWith(
        'features/prescription/presentation/widgets/fix_name_sheet.dart',
      )) {
        expect(
          text.contains('SeniorErrorBox('),
          isFalse,
          reason: '$path 가 오류를 화면에 끼워 넣는다 — 스낵바로 알린다',
        );
      }
    }
  });
}

/// 회원가입 — 한 화면에 하나만 묻고, 배타 선택을 지킨다.
void _signupTests() {
  Widget wrap(Widget child) => ProviderScope(
    child: MaterialApp(theme: AppTheme.build(), home: child),
  );

  /// 걸음 수는 역할과 성별에 따라 달라진다(임신 단계는 여성에게만 뜬다).
  /// 그러니 총 개수를 박지 않고 "지금 몇 번째인지 늘 보인다"만 지킨다.
  final stepLabel = RegExp(r'^\d+ / \d+$');

  testWidgets('걸음마다 지금 어디쯤인지 알려준다 (02~05)', (tester) async {
    await tester.pumpWidget(wrap(const SignupScreen()));
    expect(find.textContaining(stepLabel), findsOneWidget);
    // 총 개수는 박지 않는다 — 역할·성별에 따라, 그리고 묻는 것이 늘거나
    // 줄면 달라진다. 첫 걸음이 1번째라는 것만 지킨다.
    expect(find.textContaining(RegExp(r'^1 / \d+$')), findsOneWidget);
    expect(find.text('어떤 분이신가요?'), findsOneWidget);
  });

  testWidgets('역할을 고르지 않으면 스낵바로 이유를 알린다 (02)', (tester) async {
    await tester.pumpWidget(wrap(const SignupScreen()));
    await tester.tap(find.text('다음'));
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('어떤 분인지 골라주세요'), findsOneWidget);
    // 오류가 떠도 화면은 그대로다 — 다음으로 넘어가지 않는다.
    expect(find.text('어떤 분이신가요?'), findsOneWidget);
  });

  test('"잘 모르겠어요"를 누르면 고른 약 이름이 비워진다 (05)', () {
    final picked = toggleChoice({'페니실린', '아스피린'}, '잘 모르겠어요');
    expect(picked, {'잘 모르겠어요'});
  });

  test('"잘 모르겠어요" 뒤에 약을 고르면 그쪽이 빠진다 (05)', () {
    final picked = toggleChoice({'잘 모르겠어요'}, '페니실린');
    expect(picked, {'페니실린'});
  });

  test('"없어요"도 같은 규칙을 따른다 (05)', () {
    expect(toggleChoice({'고혈압', '당뇨'}, '없어요'), {'없어요'});
    expect(toggleChoice({'없어요'}, '고혈압'), {'고혈압'});
  });

  test('한 번 더 누르면 풀린다', () {
    expect(toggleChoice({'고혈압', '당뇨'}, '당뇨'), {'고혈압'});
  });

  testWidgets('기본 정보를 채우면 다음 걸음으로 넘어간다 (03)', (tester) async {
    await tester.pumpWidget(wrap(const SignupScreen()));

    await tester.tap(find.text('약을 드시는 분'));
    await tester.pump();
    await tester.tap(find.text('다음'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), '김복자');
    await tester.enterText(find.byType(TextField).at(1), '01012345678');
    await tester.enterText(find.byType(TextField).at(2), 'abc123');
    await tester.tap(find.text('다음'));
    await tester.pumpAndSettle();

    expect(find.text('생년월일과 성별을\n알려주세요'), findsOneWidget);
  });

  testWidgets('보호자는 건강 질문을 받지 않는다', (tester) async {
    await tester.pumpWidget(wrap(const SignupScreen()));
    // 보호자는 남의 복약을 지켜볼 뿐이라 자기 지병을 물을 이유가 없다.
    await tester.tap(find.text('돌보는 가족(보호자)'));
    await tester.pump();
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('되살린 건강 질문들이 글자 2배에서도 버틴다 (5h)', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.build(),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
            child: const SignupScreen(),
          ),
        ),
      ),
    );

    // 0단계 · 역할
    await tester.tap(find.text('약을 드시는 분'));
    await tester.pump();
    await tester.tap(find.text('다음'));
    await tester.pumpAndSettle();

    // 1단계 · 기본 정보
    await tester.enterText(find.byType(TextField).at(0), '김복자');
    await tester.enterText(find.byType(TextField).at(1), '01012345678');
    await tester.enterText(find.byType(TextField).at(2), 'abc123');
    await tester.tap(find.text('다음'));
    await tester.pumpAndSettle();

    // 2단계 · 생년월일과 성별
    await tester.tap(find.text('생년월일'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('여자'));
    await tester.pump();
    await tester.tap(find.text('다음'));
    await tester.pumpAndSettle();

    // 3단계 · 키·몸무게·혈액형.
    expect(find.text('혈액형'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('다음'));
    await tester.pumpAndSettle();

    // 4단계 · 임신 (여성일 때만 나온다)
    expect(find.text('젖을 먹이고 있어요'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('약을 고를 때 참고할 것들을 빠짐없이 묻는다', () {
    final source = File(
      'lib/features/auth/presentation/screens/signup_screen.dart',
    ).readAsStringSync();
    // 임신·수유는 병용금기 판정을 통째로 바꾼다. 빠지면 안 된다.
    for (final question in [
      "title: '키와 몸무게,",
      "title: '지금 임신 중이거나",
      "title: '담배와 술은",
      "title: '약물 알레르기가",
      "title: '지금 앓고 있는",
      "title: '과거에 앓았던 병이",
      "title: '가족이 앓은 병이",
      "title: '보호자 연락처를",
    ]) {
      expect(source.contains(question), isTrue, reason: '$question 단계가 없다');
    }
  });
}

/// 달력은 색과 표시만 쓴다. 칸 안에서 숫자를 세게 하지 않는다.
void _calendarTests() {
  test('달력 칸에는 복용 횟수를 적지 않는다 (19)', () {
    final source = File(
      'lib/features/dashboard/presentation/screens/month_calendar_screen.dart',
    ).readAsStringSync();
    // 칸이 가질 수 있는 상태는 정해져 있다. 기록이 없는 날은 다 드신 날로
    // 채우지 않고 따로 둔다.
    // 약 있는 날(scheduled)이 하나 더 있다. 기록이 없는 날은 여전히
    // 다 드신 날로 채우지 않는다.
    for (final mark in ['done', 'missed', 'today', 'future', 'noRecord']) {
      expect(source.contains('enum DayMark {'), isTrue);
      expect(source.contains(mark), isTrue);
    }
    // 빠뜨린 때는 색으로 끝내지 않고 글로 다시 적는다.
    // 기록 탭과 같은 하루 상세가 "못 드셨어요"까지 말해 준다.
    expect(source.contains('DayDoseDetail'), isTrue);
  });

  test('로그아웃 시트는 안전한 쪽이 주 버튼이다 (35)', () {
    final source = File(
      'lib/features/profile/presentation/widgets/logout_sheet.dart',
    ).readAsStringSync();
    final safe = source.indexOf("label: '그대로 쓸게요'");
    final logout = source.indexOf("label: '로그아웃'");
    expect(safe, greaterThan(-1));
    expect(logout, greaterThan(safe), reason: '로그아웃이 주 버튼보다 앞에 오면 안 된다');
    expect(source.contains('SeniorButtonKind.dangerQuiet'), isTrue);
  });
}

/// 센서 배선 — 화면은 상태만 읽고, 잇는 일은 [HeartSensor]가 한다.
void _sensorTests() {
  Widget wrap(Widget child) => ProviderScope(
    child: MaterialApp(theme: AppTheme.build(), home: child),
  );

  testWidgets('밖에서 센서를 넣어 주면 화면이 따로 붙지 않는다 (27)', (tester) async {
    // 넣어 준 센서는 start()를 부르지 않았으므로 idle 그대로다.
    final sensor = HeartSensor();
    addTearDown(sensor.dispose);

    await tester.pumpWidget(wrap(MeasureScreen(sensor: sensor)));

    expect(sensor.status, HeartSensorStatus.idle);
    expect(find.text('폴라 센서를 찾고 있어요'), findsOneWidget);
  });

  testWidgets('센서가 아직 값을 못 줘도 화면은 그려진다 (27)', (tester) async {
    final sensor = HeartSensor();
    addTearDown(sensor.dispose);

    await tester.pumpWidget(wrap(MeasureScreen(sensor: sensor)));
    await tester.pump(const Duration(seconds: 1));

    // 값이 없으면 "–"로 두고, 없는 숫자를 지어내지 않는다.
    expect(sensor.bpm, isNull);
    expect(find.text('–'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('배터리를 모르는 것과 0%는 다르다', () {
    final sensor = HeartSensor();
    addTearDown(sensor.dispose);
    // 기기가 알려주기 전에는 null. 0으로 두면 "다 닳았다"로 읽힌다.
    expect(sensor.battery, isNull);
    expect(sensor.batteryLow, isFalse);
  });

  testWidgets('배터리를 모르면 숫자를 지어내지 않는다 (25)', (tester) async {
    // 붙어는 있지만 배터리·측정값은 아직 안 알려준 센서.
    final sensor = _StreamingSensor();
    addTearDown(sensor.dispose);

    await tester.pumpWidget(wrap(PolarScreen(sensor: sensor)));
    await tester.pump();

    expect(find.text('폴라 센서가 연결됐어요'), findsOneWidget);
    // 예전 데모의 82%도, "다 닳았다"로 읽히는 0%도 그리지 않는다.
    expect(find.textContaining('%'), findsNothing);
    expect(find.text('아직 기기가 알려주지 않았어요'), findsOneWidget);
    expect(find.text('아직 없어요'), findsOneWidget);
  });

  testWidgets('센서를 넘겨받지 않으면 연결됐다고 하지 않는다 (25)', (tester) async {
    await tester.pumpWidget(wrap(const PolarScreen()));
    await tester.pump();
    expect(find.text('폴라 센서가 연결되지 않았어요'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('기록을 못 읽으면 예시 대신 다시 불러오기를 보여준다 (24)', (tester) async {
    final repository = _FakeHeartRepository(null);
    await tester.pumpWidget(wrap(HeartScreen(repository: repository)));

    // 읽는 중에는 숫자 자리를 비워 둔다.
    expect(find.text('심박수 기록을 불러오고 있어요'), findsOneWidget);
    await tester.pump();

    expect(find.text('심박수 기록을 불러오지 못했어요'), findsOneWidget);
    expect(find.text('다시 불러오기'), findsOneWidget);
    // 예전 데모 값(78 → 72, 9일째)이 새어 나오지 않는다.
    expect(find.text('78'), findsNothing);
    expect(find.text('72'), findsNothing);
    expect(find.text('아래는 예시 화면이에요'), findsNothing);

    repository.result = _heartSample;
    await tester.tap(find.text('다시 불러오기'));
    await tester.pump();
    await tester.pump();
    expect(find.text('오늘 측정'), findsOneWidget);
    expect(find.text('78'), findsOneWidget);
    expect(find.text('72'), findsOneWidget);
  });

  testWidgets('잰 기록이 없으면 없다고 말한다 (24)', (tester) async {
    await tester.pumpWidget(
      wrap(HeartScreen(repository: _FakeHeartRepository(_heartEmpty))),
    );
    await tester.pump();
    expect(find.text('아직 측정 기록이 없어요'), findsOneWidget);
    expect(find.text('오늘 측정'), findsNothing);
  });

  testWidgets('보호자가 어르신 id로 열면 그 기록을 읽고 재기 버튼은 없다 (24)', (tester) async {
    final repository = _FakeHeartRepository(_heartSample);
    await tester.pumpWidget(
      wrap(HeartScreen(userId: 'patient-1', repository: repository)),
    );
    await tester.pump();
    expect(repository.lastUserId, 'patient-1');
    expect(find.text('지금 측정'), findsNothing);
  });

  test('측정 전에는 최저·최고 값을 지어내지 않는다', () {
    final sensor = HeartSensor();
    addTearDown(sensor.dispose);
    expect(sensor.lowest, isNull);
    expect(sensor.highest, isNull);
  });
}

/// 넘기기 전에 되돌려야 할 것들.
void _shippingTests() {
  test('디버그와 배포 빌드 모두 실제 로그인에서 시작한다', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main.contains("initialLocation: '/login'"), isTrue);
    expect(main.contains('kSkipLogin'), isFalse);
    expect(main.contains("bool.fromEnvironment('REAL_LOGIN')"), isFalse);
  });

  test('눌러도 아무 일 없는 버튼을 남기지 않는다', () {
    // "고쳐주세요"라고 적어 놓고 고칠 방법이 없으면 틀린 채로 등록한다.
    final confirm = File(
      'lib/features/prescription/presentation/screens/prescription_screen.dart',
    ).readAsStringSync();
    expect(confirm.contains('showFixNameSheet'), isTrue);
    expect(confirm.contains("'고치기 — 아직 준비 중이에요'"), isFalse);

    final profile = File(
      'lib/features/profile/presentation/screens/mypage_screen.dart',
    ).readAsStringSync();
    expect(profile.contains('showAddCareSheet'), isTrue);
    expect(profile.contains('ProfileEditScreen'), isTrue);
  });
}

class _SeniorTestMedicationController extends MedicationController {
  _SeniorTestMedicationController()
    : super(
        apiClient: ApiClient(
          client: MockClient(
            (_) async => http.Response(
              '{}',
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        ),
      );

  @override
  TodayMedication build() {
    return const TodayMedication(
      doses: [
        DoseEntry(
          slot: DoseSlot.morning,
          medicines: [
            Medicine(ingredient: '테스트정', amount: '1알', scheduleId: 17),
          ],
          taken: true,
        ),
        DoseEntry(
          slot: DoseSlot.dinner,
          medicines: [
            Medicine(ingredient: '테스트정', amount: '1알', scheduleId: 18),
          ],
        ),
      ],
      guardianRelation: '가족',
      guardianName: '테스트',
      heartRate: 72,
      heartRateNormal: true,
    );
  }
}

/// A장 — 뒤로가기는 화살표 하나다.
///
/// 글씨는 뺐다. 칸은 그리지 않되 누르는 자리는 56×56으로 남긴다.
void _backButtonTests() {
  Widget wrap(Widget child, {double textScale = 1.0}) => ProviderScope(
    child: MaterialApp(
      theme: AppTheme.build(),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: child,
      ),
    ),
  );

  testWidgets('뒤로 버튼은 화살표만 두고 글씨는 없다', (tester) async {
    await tester.pumpWidget(
      wrap(
        Scaffold(
          body: SeniorBackHeader(title: '약 함께먹기 주의', onBack: () {}),
        ),
      ),
    );
    expect(find.byType(SeniorBackButton), findsOneWidget);
    expect(find.byIcon(TablerIcons.chevron_left), findsOneWidget);
    expect(find.text('뒤로'), findsNothing);
    expect(find.text('약 함께먹기 주의'), findsOneWidget);
  });

  testWidgets('글씨가 없어도 스크린리더는 이름을 읽는다', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      wrap(
        Scaffold(
          body: SeniorBackHeader(title: '약 함께먹기 주의', onBack: () {}),
        ),
      ),
    );
    expect(find.bySemanticsLabel('뒤로 가기'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('돌아갈 곳이 없으면 그리지 않는다', (tester) async {
    // 쉘 안에 얹힌 화면. 눌러도 아무 일 없는 버튼을 두지 않는다.
    await tester.pumpWidget(
      wrap(const Scaffold(body: SeniorBackHeader(title: '오늘'))),
    );
    expect(find.byIcon(TablerIcons.chevron_left), findsNothing);
  });

  testWidgets('제목이 길고 글자가 2배여도 버튼이 찌그러지지 않는다', (tester) async {
    await tester.pumpWidget(
      wrap(
        Scaffold(
          body: SeniorBackHeader(title: '약 함께먹기 주의', onBack: () {}),
        ),
        textScale: 2.0,
      ),
    );
    expect(tester.takeException(), isNull);
    final box = tester.getSize(find.byType(SeniorBackButton));
    expect(box.width, 56);
    expect(box.height, 56);
  });

  test('라벨 없는 아이콘 버튼이 앱 전체에 없다', () {
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final text = file.readAsStringSync();
      expect(
        text.contains('IconButton('),
        isFalse,
        reason: '${file.path} 에 라벨 없는 아이콘 버튼이 있다',
      );
      // 옛 원형 뒤로가기의 흔적.
      expect(text.contains("'‹'"), isFalse, reason: file.path);
    }
  });
}

/// B장 — 홈은 시간 축이다.
void _homeTimelineTests() {
  Widget home({required List<DoseEntry> doses}) => ProviderScope(
    overrides: [medicationProvider.overrideWith(() => _FixedMedication(doses))],
    child: MaterialApp(
      theme: AppTheme.build(),
      home: const Scaffold(body: PatientHomeScreen()),
    ),
  );

  testWidgets('굵은 테두리 카드가 하나만 있다', (tester) async {
    await tester.pumpWidget(
      home(
        doses: const [
          DoseEntry(
            slot: DoseSlot.morning,
            medicines: [Medicine(ingredient: '아침정', amount: '1알')],
            taken: true,
          ),
          DoseEntry(
            slot: DoseSlot.dinner,
            medicines: [Medicine(ingredient: '저녁정', amount: '1알')],
          ),
        ],
      ),
    );
    await tester.pump();

    // 할 일은 하나다. "먹었어요"가 두 개면 무엇을 눌러야 할지 고르게 된다.
    expect(find.text('먹었어요'), findsOneWidget);
    // 시간 축 막대는 두지 않는다 — 카드 한 장으로 말한다.
    expect(find.byType(TimelineRow), findsNothing);
  });

  testWidgets('점 3개 진행 표시가 사라졌다', (tester) async {
    await tester.pumpWidget(
      home(
        doses: const [
          DoseEntry(
            slot: DoseSlot.dinner,
            medicines: [Medicine(ingredient: '저녁정', amount: '1알')],
          ),
        ],
      ),
    );
    await tester.pump();
    expect(find.textContaining('번 드셨어요'), findsNothing);
  });

  testWidgets('바로가기는 접지 않고 늘 보인다', (tester) async {
    await tester.pumpWidget(
      home(
        doses: const [
          DoseEntry(
            slot: DoseSlot.dinner,
            medicines: [Medicine(ingredient: '저녁정', amount: '1알')],
          ),
        ],
      ),
    );
    await tester.pump();

    // 한 번 더 눌러야 나오는 기능은 없는 것과 같다.
    expect(find.textContaining('다른 기능 보기'), findsNothing);
    expect(find.textContaining('다른 기능 접기'), findsNothing);
  });

  testWidgets('심박수를 안 잰 시간대에는 행이 없다', (tester) async {
    await tester.pumpWidget(
      home(
        doses: const [
          DoseEntry(
            slot: DoseSlot.morning,
            medicines: [Medicine(ingredient: '아침정', amount: '1알')],
            taken: true,
          ),
        ],
      ),
    );
    await tester.pump();
    // 빈 카드를 두면 재야 할 것을 안 잰 것처럼 보인다.
    // 아래 바로가기의 "심박수" 타일은 늘 있는 것이라 시간 축의 행만 본다.
    expect(find.text('아침 심박수'), findsNothing);
  });

  testWidgets('잰 시간대에는 전·후가 함께 보인다', (tester) async {
    await tester.pumpWidget(
      home(
        doses: [
          DoseEntry(
            slot: DoseSlot.morning,
            medicines: const [Medicine(ingredient: '아침정', amount: '1알')],
            taken: true,
            heartCheck: DoseHeartCheck(
              before: 78,
              after: 72,
              measuredAt: DateTime(2026, 9, 18, 8, 20),
            ),
          ),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('아침 심박수'), findsOneWidget);
    expect(find.textContaining('78 → 72'), findsOneWidget);
  });

  test('심박수 문구는 빠른 쪽을 먼저 말한다', () {
    final fast = DoseHeartCheck(
      before: 90,
      after: 84,
      measuredAt: DateTime(2026, 9, 18),
    );
    // 6회 낮아졌지만 84는 여전히 빠르다. 낮아진 폭보다 먼저 알려야 한다.
    expect(fast.phrase, '조금 빨라요');
    expect(fast.isFast, isTrue);

    final calm = DoseHeartCheck(
      before: 78,
      after: 72,
      measuredAt: DateTime(2026, 9, 18),
    );
    expect(calm.phrase, '조금 낮아졌어요');

    final same = DoseHeartCheck(
      before: 74,
      after: 72,
      measuredAt: DateTime(2026, 9, 18),
    );
    expect(same.phrase, '평소와 비슷');
  });

  testWidgets('이미 드신 약은 "오늘 다른 약"에 이름으로 남는다', (tester) async {
    await tester.pumpWidget(
      home(
        doses: const [
          DoseEntry(
            slot: DoseSlot.lunch,
            medicines: [
              Medicine(ingredient: '메트포르민', amount: '1알'),
              Medicine(ingredient: '아스피린', amount: '2알'),
            ],
            taken: true,
          ),
          DoseEntry(
            slot: DoseSlot.dinner,
            medicines: [Medicine(ingredient: '저녁정', amount: '1알')],
          ),
        ],
      ),
    );
    await tester.pump();

    // 지난 복약을 행으로 쌓지 않고, 지금 카드 안에서 한 번만 말한다.
    expect(find.text('오늘 다른 약'), findsOneWidget);
    expect(find.text('메트포르민'), findsOneWidget);
    expect(find.text('아스피린'), findsOneWidget);
  });

  testWidgets('아직 오지 않은 약은 오늘 다른 약에 이름만 남긴다', (tester) async {
    await tester.pumpWidget(
      home(
        doses: const [
          DoseEntry(
            slot: DoseSlot.morning,
            medicines: [Medicine(ingredient: '아침정', amount: '1알')],
          ),
          DoseEntry(
            slot: DoseSlot.dinner,
            medicines: [Medicine(ingredient: '저녁정', amount: '1알')],
          ),
        ],
      ),
    );
    await tester.pump();

    expect(find.text('아침정'), findsOneWidget);
    expect(find.text('저녁정'), findsOneWidget);
    expect(find.text('저녁에 있어요'), findsOneWidget);
    expect(find.text('먹었어요'), findsOneWidget);
  });

  test('접고 펴는 버튼에 화살표 장식을 붙이지 않는다', () {
    // 글자가 이미 접힘 상태를 말한다. 화살표는 한 번 더 말할 뿐이다.
    final source = File(
      'lib/features/dashboard/presentation/screens/patient_home_screen.dart',
    ).readAsStringSync();
    expect(source.contains('⌄'), isFalse);
    expect(source.contains('⌃'), isFalse);
    expect(source.contains('TablerIcons.chevron_up'), isFalse);
  });
}

/// 정해진 복약 목록만 들고 있는 컨트롤러.
class _FixedMedication extends MedicationController {
  _FixedMedication(this._doses);

  final List<DoseEntry> _doses;

  @override
  TodayMedication build() => TodayMedication(
    doses: _doses,
    guardianRelation: '딸',
    guardianName: '지안',
    heartRate: 72,
    heartRateNormal: true,
  );
}

/// 값과 글자 버튼은 오른쪽 끝에 붙는다.
///
/// Expanded 라벨 옆에 Flexible 값을 두면 둘이 남은 폭을 반씩 나눠 가진다 —
/// 값이 화면 한가운데로 밀려나고, 라벨은 반 폭 안에서 두 줄로 쪼개진다.
void _rightAlignTests() {
  /// 실제 기기 폭(375)에서 본다. 값의 폭 상한을 화면 폭으로 잡으므로
  /// 테스트 기본 폭(800)에서는 카드 안 여백이 과장된다.
  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SeniorCard(child: child),
          ),
        ),
      ),
    );
  }

  testWidgets('목록 행의 값은 오른쪽 끝에 붙는다', (tester) async {
    await pump(
      tester,
      const SeniorListRow(
        label: '약 함께먹기 주의',
        icon: TablerIcons.alert_triangle,
        value: '1건',
      ),
    );

    final row = tester.getRect(find.byType(SeniorListRow));
    final value = tester.getRect(find.text('1건'));
    expect(row.right - value.right, lessThan(1));
    // 라벨이 반 폭에 갇혀 두 줄로 쪼개지지 않는다.
    expect(tester.getRect(find.text('약 함께먹기 주의')).height, lessThan(40));
  });

  testWidgets('값이 길어도 넘치지 않고 줄을 바꾼다', (tester) async {
    await pump(
      tester,
      const SeniorListRow(
        label: '이번 달',
        value: '31일 중 25일 다 드셨어요 그리고 더 긴 말이 붙어도 괜찮습니다',
      ),
    );
    expect(tester.takeException(), isNull);
  });

  test('달력에는 "약 있는 날" 표시를 두지 않는다', () {
    // 아직 안 드신 날을 따로 칠하면 다 드신 날과 헷갈린다. 지난 날의
    // 결과만 그린다.
    final source = File(
      'lib/features/dashboard/presentation/screens/month_calendar_screen.dart',
    ).readAsStringSync();
    expect(source.contains('약 있는 날'), isFalse);
    expect(source.contains('DayMark.scheduled'), isFalse);
  });
}

/// C장 — 기록도 날짜 타임라인이다.
void _recordTimelineTests() {
  testWidgets('기록 첫 화면에 오늘로 돌아가는 버튼이 있다', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          medicationProvider.overrideWith(
            () => _FixedMedication(const [
              DoseEntry(
                slot: DoseSlot.morning,
                medicines: [Medicine(ingredient: '아침정', amount: '1알')],
                taken: true,
              ),
            ]),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.build(),
          home: Scaffold(body: MedicationRecordScreen(onBackToToday: () {})),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('오늘 화면으로 돌아가기'), findsOneWidget);
  });

  test('기록 탭은 주간칸과 달력으로 가는 길만 둔다', () {
    final source = File(
      'lib/features/dashboard/presentation/screens/medication_record_screen.dart',
    ).readAsStringSync();
    // 날짜를 하나씩 카드로 늘어놓으면 화면이 길어지고, 같은 내용을
    // 달력에서 또 본다. 날짜별로 보는 일은 달력 화면이 맡는다.
    expect(source.contains('class _DayCard'), isFalse);
    expect(source.contains('class _TodayCard'), isFalse);
    // 남는 것: 이번 주 요일칸과 달력으로 가는 길. "이번 달" 달성률은
    // 눌러서 열리는 달력이 그대로 보여주므로 두지 않는다.
    expect(source.contains('class AdherenceMonthCard'), isFalse);
    expect(source.contains('class AdherenceWeekCard'), isTrue);
    expect(source.contains('MonthCalendarScreen('), isTrue);

    // 보호자 현황이 그 카드를 그대로 쓴다 — 두 화면의 그림이 갈리면
    // 통화로 맞춰 볼 수가 없다.
    final guardian = File(
      'lib/features/dashboard/presentation/screens/guardian_home_screen.dart',
    ).readAsStringSync();
    expect(guardian.contains('AdherenceWeekCard('), isTrue);
    expect(guardian.contains('MonthCalendarScreen('), isTrue);
  });

  testWidgets('달력에서 날짜를 누르면 그날 결과가 아래에 나온다', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.build(),
          home: MonthCalendarScreen(
            year: 2026,
            month: 3,
            leadingBlanks: 0,
            days: const [
              CalendarDay(
                1,
                DayMark.done,
                slots: [
                  CalendarSlot(slot: '아침', taken: true),
                  CalendarSlot(slot: '저녁', taken: true),
                ],
              ),
              CalendarDay(
                2,
                DayMark.missed,
                slots: [
                  CalendarSlot(slot: '아침', taken: true),
                  CalendarSlot(slot: '저녁', taken: false),
                ],
              ),
            ],
            missed: const [],
          ),
        ),
      ),
    );
    await tester.pump();

    // 처음에는 오늘을 보여준다.
    expect(find.textContaining('오늘'), findsWidgets);

    await tester.tap(find.text('2'));
    await tester.pump();

    expect(find.text('3월 2일'), findsOneWidget);
    // 지난 날이므로 아직 오지 않은 때가 아니라 빠뜨린 것으로 읽는다.
    expect(find.text('드셨어요'), findsOneWidget);
    expect(find.text('못 드셨어요'), findsOneWidget);

    await tester.tap(find.text('1'));
    await tester.pump();
    expect(find.text('3월 1일'), findsOneWidget);
    expect(find.text('드셨어요'), findsNWidgets(2));
  });
}

/// D장 — 내 약 목록은 드시는 때로 묶는다.
void _medicinesByTimeTests() {
  test('시간대 배지는 한글·영문을 모두 받는다', () {
    expect(slotBadgeFor(const ['아침', '저녁']), '아침 · 저녁');
    expect(slotBadgeFor(const ['MORNING', 'EVENING']), '아침 · 저녁');
    expect(slotBadgeFor(const ['저녁', '아침']), '아침 · 저녁');
  });

  test('시간대를 모르면 배지를 만들지 않는다', () {
    // 모르는 값을 "아침"으로 찍으면 엉뚱한 때에 드시게 된다.
    expect(slotBadgeFor(const []), isNull);
    expect(slotBadgeFor(const ['', '  ']), isNull);
    expect(slotBadgeFor(const ['알 수 없음']), isNull);
  });

  test('목록은 약 이름 하나만 내놓는다', () {
    // 한 줄에 배지·주성분·용량까지 얹으면 고를 것이 네 개로 보인다.
    // 자세한 것은 눌러서 들어간 약 설명이 맡는다 (프로토타입 23번).
    final source = File(
      'lib/features/medicines/presentation/screens/my_medicines_screen.dart',
    ).readAsStringSync();
    expect(source.contains('약을 누르면 설명이 나와요'), isTrue);
    // 홈과 같은 사진 자리를 쓴다. 다른 모양이면 다른 약으로 읽힌다.
    expect(source.contains('PillPhoto(size: 56)'), isTrue);
    // 지금 안 드시는 약은 줄 하나로 접어 둔다.
    expect(source.contains('이전에 등록한 약'), isTrue);
  });
}

/// E·F장 — 등록 전 미리보기, 재알림 문구.
void _confirmPreviewTests() {
  final confirm = File(
    'lib/features/prescription/presentation/screens/prescription_screen.dart',
  ).readAsStringSync();

  test('OCR 확인 화면은 원문 이름과 공식 품목 식별자를 구분한다', () {
    // 화면에는 구구절절 적지 않는다(프로토타입 78). 다만 사진에서 읽은
    // 이름과 공식 품목은 코드 안에서 끝까지 구분해서 들고 간다.
    expect(confirm.contains('ocr_drug_name_raw'), isTrue);
    expect(confirm.contains('official_product_name'), isTrue);
    expect(confirm.contains('medicine_code'), isTrue);
  });

  test('OCR 확인 화면은 근거 없는 내일 복약 시각을 만들지 않는다', () {
    // 프로토타입 78에는 "내일부터 이렇게 됩니다"가 있다. 다만 서버가 준
    // 시간대가 없으면 그리지 않는다 — 시각을 지어내지 않는다.
    expect(confirm.contains('내일부터 이렇게 됩니다'), isTrue);
    expect(confirm.contains('if (bySlot.isEmpty) return const [];'), isTrue);
    expect(
      confirm.contains(
        "'administration_times': item['administration_times'] is List",
      ),
      isTrue,
    );
  });

  test('재알림은 절대시각으로 말한다', () {
    final home = File(
      'lib/features/dashboard/presentation/screens/patient_home_screen.dart',
    ).readAsStringSync();
    expect(home.contains('에 다시 알려드려요'), isTrue);
    // "나중에 확인"처럼 무엇이 일어나는지 모를 문구를 쓰지 않는다.
    expect(home.contains('나중에 확인'), isFalse);
  });
}

/// 3장 — 화면별 문구·경로가 9/11 병합에서 빠졌던 자리들.
void _screenCopyTests() {
  test('손으로 적기는 확인되지 않은 복용 시각을 만들지 않는다 (10)', () {
    final source = File(
      'lib/features/prescription/presentation/screens/manual_medicine_screen.dart',
    ).readAsStringSync();
    // 시각을 지어내지 않는다 — 드시는 때를 고르지 않으면 등록하지 않는다.
    expect(source.contains('드시는 때를 한 개 이상 골라 주세요.'), isTrue);
    expect(source.contains("'administration_times': _slots.toList()"), isTrue);
    expect(source.contains('공식 약 이름을 찾지 못했어요.'), isTrue);
  });

  test('설정에는 화면 모드 칸이 없다', () {
    // 모드는 홈 헤더의 배지 하나로만 바꾼다. 같은 스위치를 두 군데 두면
    // 어느 쪽이 지금 상태인지 서로 어긋나 보인다.
    final source = File(
      'lib/features/profile/presentation/screens/mypage_screen.dart',
    ).readAsStringSync();
    expect(source.contains("Text('화면 모드'"), isFalse);
    expect(source.contains("labels: const ['일반', '쉬운 화면']"), isFalse);
  });

  test('쉬운 화면으로 가는 길은 홈 헤더에 남아 있다', () {
    final source = File(
      'lib/features/dashboard/presentation/screens/patient_home_screen.dart',
    ).readAsStringSync();
    expect(source.contains('ModeBadge()'), isTrue);
  });
}

/// 색은 AppColors 에서만 나온다.
///
/// 화면마다 리터럴을 두면 같은 회색이 조금씩 달라지고, 나중에 한 번에
/// 바꿀 수도 없다.
void _colorTokenTests() {
  test('AppColors 밖에 색 리터럴이 없다', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      // 윈도우는 경로를 역슬래시로 준다. 맞춰 두지 않으면 색 토큰을
      // 정의한 파일 자신이 위반으로 잡힌다.
      final path = file.path.replaceAll(r'\', '/');
      if (path.endsWith('core/constants/app_colors.dart')) continue;
      if (path.endsWith(
        'features/prescription/presentation/screens/prescription_screen.dart',
      )) {
        continue;
      }
      final text = file.readAsStringSync();
      for (final match in RegExp(
        r'Color\(0x[0-9A-Fa-f]{8}\)',
      ).allMatches(text)) {
        offenders.add('${file.path}: ${match.group(0)}');
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}

/// 로그인 UI는 실제 서버 응답만 세션으로 받아야 한다.
void _realLoginTests() {
  test('가짜 로그인 분기 없이 서버 로그인 후 세션을 연다', () {
    final login = File(
      'lib/features/auth/presentation/screens/login_screen.dart',
    ).readAsStringSync();
    expect(login.contains('_fakeLogin'), isFalse);
    expect(login.contains("id: 'mvp-user'"), isFalse);
    expect(login.contains('.login(phone:'), isTrue);
    expect(login.contains('await startSession(ref, user)'), isTrue);
  });

  test('보호 화면은 인증되지 않으면 로그인으로 돌린다', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main.contains('if (!AuthSession.isLoggedIn)'), isTrue);
    expect(main.contains("publicRoute ? null : '/login'"), isTrue);
  });
}
