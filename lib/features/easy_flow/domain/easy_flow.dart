import 'package:flutter/foundation.dart';

/// 쉬운 모드가 지나가는 화면.
///
/// 일반 모드가 쓰는 화면을 그대로 부른다.
/// 등록 뒤 약 있는 날 달력만 예외로, 두 모드가 같은 확인 화면을 쓴다.
enum EasyScreen {
  today,
  done,
  record,
  heart,
  medicines,
  prescription,
  interaction,
  scheduleDays,
  myInfo,
  chat,
  measure,
}

/// 한 걸음.
@immutable
class EasyStep {
  final EasyScreen screen;

  /// 하단 바 버튼에 쓸 말. "다음 한 걸음"이 무엇인지 그대로 적는다.
  final String nextLabel;

  const EasyStep({required this.screen, required this.nextLabel});
}

/// 다음 한 걸음 순서.
///
/// 하루에 실제로 일어나는 차례를 따른다.
/// 흐름 밖 화면에서는 라벨이 "오늘 화면으로 가기"가 된다.
const List<EasyStep> kEasyFlow = [
  EasyStep(screen: EasyScreen.today, nextLabel: '복약 완료 보기'),
  EasyStep(screen: EasyScreen.done, nextLabel: '복약 기록 보기'),
  EasyStep(screen: EasyScreen.record, nextLabel: '심박수 보기'),
  EasyStep(screen: EasyScreen.heart, nextLabel: '내 약 목록 보기'),
  EasyStep(screen: EasyScreen.medicines, nextLabel: '오늘 화면으로 가기'),
];

/// 흐름 밖 화면에서 쓰는 라벨.
const String kEasyFallbackLabel = '오늘 화면으로 가기';

/// 쉬운 모드 메뉴에서 바로 갈 수 있는 곳.
///
/// 흐름을 따라가다 길을 잃어도 여기서 원하는 화면으로 바로 간다.
const List<EasyDestination> kEasyMenu = [
  EasyDestination('오늘 먹을 약', EasyScreen.today),
  EasyDestination('복약 기록', EasyScreen.record),
  EasyDestination('내 약 설명', EasyScreen.medicines),
  EasyDestination('AI 약사 상담', EasyScreen.chat),
  EasyDestination('심박수 관리', EasyScreen.heart),
  EasyDestination('심박수 측정', EasyScreen.measure),
  EasyDestination('처방전 넣기', EasyScreen.prescription),
  EasyDestination('함께먹기 주의', EasyScreen.interaction),
  EasyDestination('복약 완료', EasyScreen.done),
  EasyDestination('내 정보', EasyScreen.myInfo),
];

@immutable
class EasyDestination {
  final String label;
  final EasyScreen screen;

  const EasyDestination(this.label, this.screen);
}

/// 하단 바를 숨길 화면.
///
/// 측정 중이거나, 등록 뒤 약 있는 날을 확인하는 화면에서는
/// "다음 한 걸음"이 방해가 된다. 그 화면들은 자기 단추로 마친다.
bool showsEasyBar(EasyScreen screen) =>
    screen != EasyScreen.measure && screen != EasyScreen.scheduleDays;

/// 하단 바가 뜰 때 스크롤 아래에 둘 여백.
/// 바가 마지막 카드를 가리지 않게 한다.
const double kEasyBarScrollPadding = 140;
