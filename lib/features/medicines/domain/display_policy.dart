/// 홈·목록·상세·기록·알림에 공통으로 쓰는 표시 규칙.
library;

const _placeholderSpoken = '처방받은 약이에요';

const _spokenAliases = <String, String>{
  '피를 묽게 하는 약이에요': '피가 굳지 않게 하는 약이에요',
  '피를 묽게 하는 약이에요.': '피가 굳지 않게 하는 약이에요',
};

const _easyLabelAliases = <String, String>{
  '피 묽게 하는 약': '피가 굳지 않게 하는 약',
  '피 묽게': '피가 굳지 않게 하는 약',
  '피를 묽게 하는 약': '피가 굳지 않게 하는 약',
  '혈압 낮춤': '혈압약',
  '혈당 조절': '당뇨약',
};

final _permissionNameHint = RegExp(r'(정|캡슐|캅셀|액|시럽|연고|밀리그램|밀리그람)');
final _exportAliasParen = RegExp(
  r'\s*\((?:수출\s*명\s*[:：]?|수출\s*용|수출용\s*별칭)[^)]*\)',
  caseSensitive: false,
);

class MyMedicineCard {
  final String name;
  final String? purposeLabel;
  final String? spoken;

  const MyMedicineCard({required this.name, this.purposeLabel, this.spoken});
}

String normalizeEasyLabel(String? label) {
  final text = (label ?? '').trim();
  return _easyLabelAliases[text] ?? text;
}

/// 서버 버전이 오래되어도 수출용 별칭은 화면에 노출하지 않는다.
String stripExportAlias(String? name) {
  final text = (name ?? '').trim();
  if (text.isEmpty) return '';
  return text
      .replaceAll(_exportAliasParen, '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String stripEasyCategoryParen(String? name) {
  final text = stripExportAlias(name);
  final match = RegExp(r'\s*\(([^)]*)\)\s*$').firstMatch(text);
  if (match == null) return text;
  final inner = match.group(1)?.trim() ?? '';
  if (_isCategoryParen(inner)) {
    return text.substring(0, match.start).trim();
  }
  return text;
}

/// 요약 화면에서만 제품명 뒤에 중복된 주성분 괄호를 숨긴다.
/// DB와 OCR 확인 화면의 공식 제품명은 바꾸지 않는다.
String compactProductName(String? name, {String? ingredient}) {
  final text = stripEasyCategoryParen(stripExportAlias(name));
  final match = RegExp(r'\s*\(([^)]*)\)\s*$').firstMatch(text);
  if (match == null) return text;
  final innerKey = _ingredientCompareKey(match.group(1));
  if (innerKey.isEmpty) return text;
  // 서버가 오래된 이름을 보내더라도, 영문 성분값과 제품명 한글 괄호를
  // 같은 성분으로 비교해 중복 괄호만 숨긴다. 원본 데이터는 바꾸지 않는다.
  final preferredIngredient = preferredCardIngredient(
    ingredient,
    productName: text,
  );
  final comparisonIngredient = preferredIngredient.isNotEmpty
      ? preferredIngredient
      : ingredient;
  final ingredientKeys = ingredientParts(
    comparisonIngredient,
  ).map(_ingredientCompareKey).where((key) => key.isNotEmpty).toSet();
  if (ingredientKeys.contains(innerKey)) {
    return text.substring(0, match.start).trim();
  }
  return text;
}

String _ingredientCompareKey(String? value) {
  return (value ?? '')
      .replaceAll(
        RegExp(
          r'\d+(?:\.\d+)?\s*(?:mg|mL|g|%|밀리그램|밀리그람|밀리리터)',
          caseSensitive: false,
        ),
        '',
      )
      .toLowerCase()
      .replaceAll(RegExp(r'[^0-9a-z가-힣]'), '');
}

/// 영문 성분명만 있을 때 제품명의 한글 성분 괄호를 우선한다.
String preferredCardIngredient(String? ingredient, {String? productName}) {
  final raw = (ingredient ?? '').trim();
  final product = stripExportAlias(productName);
  final match = RegExp(r'\(([^()]*)\)\s*$').firstMatch(product);
  final fromProduct = match?.group(1)?.trim() ?? '';
  final rawHasHangul = RegExp(r'[가-힣]').hasMatch(raw);
  final productHasHangul = RegExp(r'[가-힣]').hasMatch(fromProduct);
  if (!rawHasHangul && productHasHangul && !_isCategoryParen(fromProduct)) {
    return fromProduct;
  }
  // 영문만 있고 한글 성분명을 보완할 근거가 없으면 어르신 화면에 만 노출하지 않는다.
  return rawHasHangul ? raw : '';
}

String cardIngredientCaption(
  String? ingredient, {
  String? productName,
  String? strength,
}) {
  final name = preferredCardIngredient(ingredient, productName: productName);
  final dose = (strength ?? '').trim();
  if (name.isEmpty) return '';
  if (dose.isEmpty || name.contains(dose)) return name;
  return '$name · $dose';
}

bool _isCategoryParen(String inner) {
  final text = normalizeEasyLabel(inner);
  if (text.contains('·') || text.contains(',')) return true;
  if (isCardPurposeLabel(text)) return true;
  return inner.contains('묽게') ||
      inner.contains('낮춤') ||
      inner.contains('조절') ||
      inner.contains('속쓰림') ||
      inner.contains('알레르기') ||
      inner.contains('두통');
}

bool isMockDrugInfoName(String? name) {
  final compact = stripEasyCategoryParen(
    name,
  ).replaceAll(RegExp(r'\s+'), '').toLowerCase();
  return compact == '아스피린100mg' ||
      compact == '암로디핀5mg' ||
      compact == '메트포르민500mg';
}

bool looksLikePermissionProductName(String? name) {
  final text = stripEasyCategoryParen(name);
  if (text.isEmpty) return false;
  return _permissionNameHint.hasMatch(text);
}

/// 카드 제목은 허가 제품명. 성분+키워드 괄호는 제목으로 쓰지 않는다.
String cardOfficialName({
  String? productName,
  String? displayName,
  String? ingredient,
}) {
  final candidates = <String?>[productName, displayName, ingredient];
  for (final raw in candidates) {
    final stripped = compactProductName(raw, ingredient: ingredient);
    if (stripped.isEmpty) continue;
    if (looksLikePermissionProductName(raw) ||
        looksLikePermissionProductName(stripped)) {
      return stripped;
    }
  }
  for (final raw in candidates) {
    final stripped = compactProductName(raw, ingredient: ingredient);
    if (stripped.isNotEmpty) return stripped;
  }
  return '약';
}

/// 짧은 분류로 쓸 수 있는 쉬운말인지. 증상 키워드 나열은 false.
bool isCardPurposeLabel(String? label) {
  final text = normalizeEasyLabel(label);
  if (text.isEmpty) return false;
  if (text.contains('완화') || text.contains('약이에요')) return true;
  if (text.endsWith('약') || text.endsWith('제') || text.contains('하는 약')) {
    return true;
  }
  return false;
}

String? cardPurposeLabel(String? raw) {
  final text = (raw ?? '').trim();
  if (text.isEmpty) return null;
  final parts = text
      .split(' · ')
      .map(normalizeEasyLabel)
      .where((part) => part.isNotEmpty && isCardPurposeLabel(part))
      .toList();
  final unique = <String>[];
  for (final part in parts) {
    if (!unique.contains(part)) unique.add(part);
  }
  if (unique.isEmpty) return null;
  return unique.join(' · ');
}

/// 홈 짧은 분류. 주제는 쉼표로 모두 적고 `약`은 끝에 한 번만 붙인다.
String? homePurposeCaption(String? raw) {
  final labeled = cardPurposeLabel(raw);
  if (labeled == null) return null;
  final topics = <String>[];
  for (final chunk in labeled.split(' · ')) {
    var topic = chunk.replaceAll(RegExp('[·ㆍ]'), ' ');
    topic = topic.replaceAll(RegExp(r'\s+'), ' ').trim();
    topic = topic.replaceFirst(RegExp(r'(완화|약|제)$'), '').trim();
    if (topic.isEmpty || topics.contains(topic)) continue;
    topics.add(topic);
  }
  if (topics.isEmpty) return null;
  return '${topics.join(', ')} 약';
}

String? cardSpokenOf(String? text) {
  var value = (text ?? '').trim();
  value = _spokenAliases[value] ?? value;
  if (value.isEmpty || value == _placeholderSpoken) return null;
  if (value.contains('목적으로 처방') || value.contains('목적으로 사용')) {
    return null;
  }
  return value;
}

/// 상세 화면은 검토된 한 문장 설명을 보여 준다.
/// 홈·목록의 중복 제거 규칙(`목적으로 처방`)을 적용하지 않는다.
String? detailSpokenOf(String? text) {
  var value = (text ?? '').trim();
  value = _spokenAliases[value] ?? value;
  if (value.isEmpty || value == _placeholderSpoken) return null;
  return value;
}

final _usageNumbered = RegExp(r'(?<!\d)(\d+\.\s+)(?=[가-힣○•])');
final _usageStandaloneNumber = RegExp(r'^\s*(\d+\.)\s*\n+\s*', multiLine: true);
final _usagePersonLabel = RegExp(
  r'(?<!\d\.)(?<=\S)[ \t]+(신기능부전 환자|신기능 저하 환자|간기능 저하 환자|성인|소아|고령자)\s*[:：]',
);
final _usageBullet = RegExp(r'\s*[○•]\s*');
final _usageSentenceEnd = RegExp(r'(한다\.|이다\.)\s+');

/// 허가 용법 원문은 그대로 두고, 항·문장 앞에서만 줄을 나눈다.
String formatOfficialUsage(String? raw) {
  var text = (raw ?? '').replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  text = text.replaceAllMapped(
    _usageStandaloneNumber,
    (match) => '${match[1]} ',
  );
  text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
  text = text.replaceAll(RegExp(r' *\n *'), '\n');
  text = text.replaceAll(_usageBullet, '\n\n○ ');
  text = text.replaceAllMapped(_usageNumbered, (match) => '\n\n${match[1]}');
  text = text.replaceAllMapped(
    _usagePersonLabel,
    (match) => '\n\n${match[1]} : ',
  );
  text = text.replaceAllMapped(_usageSentenceEnd, (match) => '${match[1]}\n\n');
  text = text.replaceAll(RegExp(r' : +'), ' : ');
  text = text.replaceAllMapped(
    RegExp(r'\s+(고령자)\s+(이 약은)'),
    (match) => '\n\n${match[1]} ${match[2]}',
  );
  return text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

/// 긴 복합제 성분은 카드에서 첫 성분과 나머지 개수만 보여 준다.
/// 원문은 모델에 그대로 보존하므로 상세 화면에서는 전체 성분을 쓸 수 있다.
List<String> ingredientParts(String? raw) {
  final text = (raw ?? '').trim();
  if (text.isEmpty) return const [];
  final parts = text
      .split(RegExp(r'[|;\n\r]+'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList();
  final unique = <String>[];
  for (final part in parts) {
    if (!unique.contains(part)) unique.add(part);
  }
  return unique;
}

String compactIngredientSummary(String? raw) {
  final parts = ingredientParts(raw);
  if (parts.isEmpty) return '';
  if (parts.length == 1) return parts.first;
  return '${parts.first} 외 ${parts.length - 1}개';
}

/// 홈·목록·상세·기록·알림이 같은 이름·설명을 쓰게 한곳에서 고른다.
MyMedicineCard resolveMyMedicineCard({
  String? medicineCode,
  String? productName,
  String? displayName,
  String? ingredient,
  String? purposeLabel,
  String? shortExplanation,
  String? easyCategory,
}) {
  final name = cardOfficialName(
    productName: productName,
    displayName: displayName,
    ingredient: ingredient,
  );
  var purpose = cardPurposeLabel(purposeLabel);
  var spoken = cardSpokenOf(shortExplanation) ?? cardSpokenOf(easyCategory);
  return MyMedicineCard(name: name, purposeLabel: purpose, spoken: spoken);
}
