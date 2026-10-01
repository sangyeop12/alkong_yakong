import 'package:alkong_yakong/features/medicines/domain/display_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('허가 제품명을 우선하고 중복 주성분 괄호는 뗀다', () {
    final card = resolveMyMedicineCard(
      medicineCode: '197800210',
      productName: '아디팜정(히드록시진염산염)',
      displayName: '히드록시진염산염 (알레르기·두통·어지러움)',
      ingredient: '히드록시진염산염',
      purposeLabel: '가려움 완화 · 불안·긴장 완화',
      shortExplanation: '가려움 또는 불안·긴장을 완화할 목적으로 처방될 수 있어요.',
      easyCategory: '가려울 때 먹는 약이에요',
    );
    expect(card.name, '아디팜정');
    expect(card.purposeLabel, '가려움 완화 · 불안·긴장 완화');
    expect(card.spoken, '가려울 때 먹는 약이에요');
    expect(card.spoken, isNot(contains('목적으로 처방')));
  });

  test('시메티딘도 허가명과 속쓰림 설명을 쓴다', () {
    final card = resolveMyMedicineCard(
      productName: '휴온스시메티딘정200밀리그램',
      displayName: '시메티딘 (속쓰림·위·소화·알레르기)',
      ingredient: '시메티딘',
      purposeLabel: '속쓰림·위산 역류 완화',
      shortExplanation: '위산을 줄여 속쓰림과 위산 역류를 완화하는 약이에요.',
    );
    expect(card.name, '휴온스시메티딘정200밀리그램');
    expect(card.purposeLabel, '속쓰림·위산 역류 완화');
    expect(card.spoken, contains('위산을 줄여'));
  });

  test('서버 설명이 없으면 특정 약 하드코딩 문구를 만들지 않는다', () {
    final card = resolveMyMedicineCard(
      medicineCode: '197800210',
      productName: '아디팜정(히드록시진염산염)',
    );
    expect(card.spoken, isNull);
    expect(card.purposeLabel, isNull);
  });

  test('수출명만 제거하고 성분 괄호는 보존한다', () {
    expect(stripExportAlias('제품정(수출명 : TAGAMENT)(성분명)'), '제품정(성분명)');
    expect(stripExportAlias('아디팜정(히드록시진염산염)'), '아디팜정(히드록시진염산염)');
  });

  test('요약 화면은 주성분과 같은 마지막 괄호만 숨긴다', () {
    expect(
      compactProductName('코다론정(아미오다론염산염)', ingredient: '아미오다론염산염'),
      '코다론정',
    );
    expect(compactProductName('제품정(서방정)', ingredient: '성분명'), '제품정(서방정)');
  });

  test('영문 주성분은 숨기고 제품명 한글 괄호를 쓴다', () {
    expect(
      preferredCardIngredient(
        'Prednicarbate',
        productName: '프레벨액0.25%(프레드니카르베이트)',
      ),
      '프레드니카르베이트',
    );
    expect(
      cardIngredientCaption(
        'Prednicarbate',
        productName: '프레벨액0.25%(프레드니카르베이트)',
        strength: '0.25%',
      ),
      '프레드니카르베이트 · 0.25%',
    );
    expect(
      compactProductName(
        '프레벨액0.25%(프레드니카르베이트)',
        ingredient: preferredCardIngredient(
          'Prednicarbate',
          productName: '프레벨액0.25%(프레드니카르베이트)',
        ),
      ),
      '프레벨액0.25%',
    );
    expect(
      preferredCardIngredient('Prednicarbate', productName: '프레벨액0.25%'),
      '',
    );
  });

  test('홈 짧은 분류는 주제를 쉼표로 잇고 약은 끝에 한 번만 붙인다', () {
    expect(homePurposeCaption('심장 박동 약'), '심장 박동 약');
    expect(homePurposeCaption('가려움 약'), '가려움 약');
    expect(homePurposeCaption('가려움 완화 · 불안·긴장 완화'), '가려움, 불안 긴장 약');
    expect(
      homePurposeCaption('가려움 완화 · 불안·긴장 완화 · 속쓰림 약'),
      '가려움, 불안 긴장, 속쓰림 약',
    );
    expect(homePurposeCaption('속쓰림·위산 역류 완화'), '속쓰림 위산 역류 약');
    expect(homePurposeCaption(null), isNull);
  });

  test('공식 용법은 숫자 용량을 바꾸지 않고 항만 줄바꿈한다', () {
    const raw =
        '○ 성인 1. 정신과 영역 2. 피부과 영역 고령자 이 약은 가능한한 최단 기간 동안 '
        '최소 유효 용량으로 투여해야 한다. 성인 : 1일 50mg을 3회 분할 '
        '(12.5mg, 12.5mg, 25mg) 경구 투여한다. 성인에서 최대용량은 1일 100mg이다.';
    final formatted = formatOfficialUsage(raw);
    expect(formatted, contains('1일 50mg'));
    expect(formatted, contains('12.5mg'));
    expect(formatted, contains('\n\n1. 정신과'));
    expect(formatted, contains('\n\n2. 피부과'));
    expect(formatted, contains('성인 : 1일 50mg'));
    expect(formatted.split('\n\n').length, greaterThan(3));
  });
}
