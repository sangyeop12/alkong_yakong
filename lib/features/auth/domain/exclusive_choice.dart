/// 다른 것과 함께 고를 수 없는 답.
///
/// "잘 모르겠어요"와 "없어요"가 그렇다. 페니실린과 "잘 모르겠어요"를 함께
/// 고르면 무엇도 확실하지 않은 답이 되어 위험한 약을 걸러낼 수 없다.
const Set<String> kExclusiveChoices = {'잘 모르겠어요', '없어요'};

/// 칩 하나를 눌렀을 때 고른 집합이 어떻게 되는지.
///
/// 배타 항목을 누르면 그것만 남고, 다른 항목을 누르면 배타 항목이 빠진다.
/// **경고를 띄우고 되돌리게 하지 않는다** — 누른 대로 정리해 준다.
Set<String> toggleChoice(Set<String> selected, String choice) {
  if (selected.contains(choice)) {
    return {...selected}..remove(choice);
  }
  if (kExclusiveChoices.contains(choice)) {
    return {choice};
  }
  return {...selected.where((s) => !kExclusiveChoices.contains(s)), choice};
}
