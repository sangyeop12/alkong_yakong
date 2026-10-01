import 'package:flutter/foundation.dart';

/// 약 하나의 쉬운 말 설명.
///
/// 문구는 05-CONTENT-RULES의 원문을 그대로 쓴다.
/// 의학 용어 대신 일상어를 쓰고("피를 묽게 하는 약"), 숫자를 그냥 던지지 않는다.
@immutable
class DrugInfo {
  /// 'met' / 'aml' / 'asp'.
  final String key;

  final String name;

  /// "흰색 동그란 알약".
  final String appearance;

  /// "한 번에 1알 · 하루 2번".
  final String dosage;

  /// 효능 한 줄 — "혈당 낮추는 약".
  final String effect;

  /// 무슨 약이에요?
  final String what;

  /// 언제 드세요.
  final String when;

  /// 식사와의 관계.
  final String withMeal;

  /// 이런 게 있을 수 있어요.
  final String sideEffects;

  /// 이럴 때는 바로 알려주세요.
  final String warning;

  const DrugInfo({
    required this.key,
    required this.name,
    required this.appearance,
    required this.dosage,
    required this.effect,
    required this.what,
    required this.when,
    required this.withMeal,
    required this.sideEffects,
    required this.warning,
  });

  static const DrugInfo metformin = DrugInfo(
    key: 'met',
    name: '메트포르민 500mg',
    appearance: '흰색 동그란 알약',
    dosage: '한 번에 1알 · 하루 2번',
    effect: '혈당 낮추는 약',
    what:
        '몸에서 당을 잘 쓰게 도와 혈당을 낮춰 줍니다. '
        '당뇨약 중에서 가장 오래, 가장 많이 쓰이는 약이에요.',
    when: '아침·저녁 하루 두 번, 같은 시간에 드세요.',
    withMeal: '밥을 드신 바로 뒤에 드시면 속이 덜 불편합니다.',
    sideEffects:
        '처음 며칠은 속이 더부룩하거나 설사가 있을 수 있어요. '
        '대개 1~2주면 나아집니다.',
    warning:
        '숨이 차고 몸에 힘이 쭉 빠질 때, 토가 멈추지 않을 때는 '
        '약을 멈추고 바로 병원에 가세요.',
  );

  static const DrugInfo amlodipine = DrugInfo(
    key: 'aml',
    name: '암로디핀 5mg',
    appearance: '노란 길쭉한 알약',
    dosage: '한 번에 1알 · 하루 1번',
    effect: '혈압 내리는 약',
    what:
        '혈관을 넓혀 피가 잘 흐르게 해서 혈압을 내려 줍니다. '
        '매일 먹어야 효과가 유지돼요.',
    when: '저녁 6시에 하루 한 번 드세요.',
    withMeal: '밥과 상관없이 드셔도 됩니다. 자몽 주스는 피해 주세요.',
    sideEffects:
        '발목이 붓거나 얼굴이 달아오를 수 있어요. '
        '어지러우면 천천히 일어나세요.',
    warning:
        '발목 부기가 심해지거나, 앉았다 일어날 때 눈앞이 캄캄해지면 '
        '알려주세요.',
  );

  static const DrugInfo aspirin = DrugInfo(
    key: 'asp',
    name: '아스피린 100mg',
    appearance: '작은 흰색 알약',
    dosage: '한 번에 1알 · 하루 1번',
    effect: '피를 묽게 하는 약',
    what:
        '피가 굳어 혈관을 막는 것을 예방합니다. '
        '심장·뇌를 지키기 위해 매일 드시는 약이에요.',
    when: '아침 8시에 하루 한 번 드세요.',
    withMeal: '밥을 드신 뒤에 물을 넉넉히 마시며 드세요.',
    sideEffects: '속이 쓰릴 수 있어요. 멍이 잘 들고 상처의 피가 늦게 멈춥니다.',
    warning:
        '검은색 변이 나오거나, 코피·잇몸 피가 잘 멈추지 않으면 '
        '바로 알려주세요. 와파린과 같이 드시면 안 됩니다.',
  );

  static const List<DrugInfo> all = [metformin, amlodipine, aspirin];

  /// 성분명이나 키로 찾는다. 못 찾으면 null.
  static DrugInfo? find(String? keyOrName) {
    if (keyOrName == null) return null;
    for (final drug in all) {
      if (drug.key == keyOrName || drug.name == keyOrName) return drug;
    }
    return null;
  }
}

/// AI 약사가 답할 수 있는 추천 질문과 원문 답변.
@immutable
class PharmacistAnswer {
  final String question;
  final String answer;

  const PharmacistAnswer(this.question, this.answer);

  /// 모든 답변 아래에는 **항상** 이 문장이 붙는다.
  static const String disclaimer = '약을 바꾸거나 끊는 결정은 꼭 약사·의사와 상의하세요.';

  static const List<PharmacistAnswer> suggested = [
    PharmacistAnswer(
      '이 약은 왜 먹는 거예요?',
      '처방전으로 넣으신 약은 홈 카드의 한 문장 설명을 먼저 보시면 됩니다. '
          '내가 이 약을 받는 이유는 의사나 약사에게 확인해 주세요.',
    ),
    PharmacistAnswer(
      '약을 깜빡했으면 어떡해요?',
      '생각나신 때가 다음 약 시간까지 4시간 이상 남았으면 지금 한 알 드세요. '
          '다음 시간이 가까우면 그냥 넘기시고, 두 알을 한꺼번에 드시지는 마세요.',
    ),
    PharmacistAnswer(
      '밥 안 먹고 먹어도 돼요?',
      '속이 쓰린 약은 밥을 드신 뒤에 드시는 편이 편할 수 있어요. '
          '약마다 달라서, 홈 설명과 약사 안내를 함께 보시면 됩니다.',
    ),
  ];
}
