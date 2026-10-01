import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../theme/app_typography.dart';
import 'senior_sheet.dart';

/// 굴려서 고르는 창.
///
/// 회원가입에서 생년월일을 고르는 그 모양 하나로 앱 전체를 맞춘다 —
/// 아래에서 올라오는 흰 판, 왼쪽에 무엇을 고르는지, 오른쪽에 "확인".
/// 높이는 화면의 절반이라 굴릴 자리가 넉넉하다.
///
/// 고른 자리의 번호를 돌려준다. 그만두면 null.
Future<int?> showSeniorWheel({
  required BuildContext context,
  required String title,
  required List<String> options,
  int selectedIndex = 0,

  /// 제목 오른쪽 확인 단추 이름. 기본은 "확인".
  String? confirmLabel,

  /// 굴림판 아래에 붙일 단추들. 없으면 두지 않는다.
  List<Widget> extraButtons = const [],
}) {
  if (options.isEmpty) return Future<int?>.value();
  var index = selectedIndex.clamp(0, options.length - 1);
  return _showPickerSheet<int>(
    context: context,
    title: title,
    confirmLabel: confirmLabel,
    onConfirm: () => index,
    extraButtons: extraButtons,
    builder: (_) => _Wheel(
      count: options.length,
      initialIndex: index,
      labelOf: (i) => options[i],
      onChanged: (i) => index = i,
    ),
  );
}

/// 시각을 고르는 창 — 왼쪽에 오전·오후, 오른쪽에 시.
///
/// 24시간제 시각(0~23)을 돌려준다. 그만두면 null.
Future<int?> showSeniorTimeWheel({
  required BuildContext context,
  required String title,
  int initialHour = 8,
}) {
  final hour = initialHour.clamp(0, 23);
  var meridiem = hour < 12 ? 0 : 1;
  final twelve = hour % 12;
  var clockHour = twelve == 0 ? 12 : twelve;

  int hour24() {
    if (meridiem == 0) return clockHour == 12 ? 0 : clockHour;
    return clockHour == 12 ? 12 : clockHour + 12;
  }

  return _showPickerSheet<int>(
    context: context,
    title: title,
    onConfirm: hour24,
    builder: (_) => Row(
      children: [
        Expanded(
          flex: 2,
          child: _Wheel(
            count: 2,
            initialIndex: meridiem,
            labelOf: (i) => i == 0 ? '오전' : '오후',
            onChanged: (i) => meridiem = i,
          ),
        ),
        Expanded(
          flex: 2,
          child: _Wheel(
            count: 12,
            initialIndex: clockHour - 1,
            labelOf: (i) => '${i + 1}시',
            onChanged: (i) => clockHour = i + 1,
          ),
        ),
      ],
    ),
  );
}

/// 날짜를 고르는 창 — 년·월·일.
///
/// 고른 날짜를 돌려준다. 그만두면 null.
Future<DateTime?> showSeniorDateWheel({
  required BuildContext context,
  String title = '생년월일',
  DateTime? initialDate,
  int firstYear = 1920,
}) {
  final now = DateTime.now();
  final start = initialDate ?? DateTime(now.year - 60, 1, 1);
  final years = [for (int y = firstYear; y <= now.year; y++) y];
  var year = start.year.clamp(firstYear, now.year);
  var month = start.month;
  var day = start.day;

  return _showPickerSheet<DateTime>(
    context: context,
    title: title,
    onConfirm: () {
      // 2월 31일 같은 날은 그 달의 마지막 날로 내린다.
      final maxDay = DateUtils.getDaysInMonth(year, month);
      return DateTime(year, month, day > maxDay ? maxDay : day);
    },
    builder: (_) => Row(
      children: [
        Expanded(
          flex: 3,
          child: _Wheel(
            count: years.length,
            initialIndex: years.contains(year) ? years.indexOf(year) : 0,
            labelOf: (i) => '${years[i]}년',
            onChanged: (i) => year = years[i],
          ),
        ),
        Expanded(
          flex: 2,
          child: _Wheel(
            count: 12,
            initialIndex: month - 1,
            labelOf: (i) => '${i + 1}월',
            onChanged: (i) => month = i + 1,
          ),
        ),
        Expanded(
          flex: 2,
          child: _Wheel(
            count: 31,
            initialIndex: day - 1,
            labelOf: (i) => '${i + 1}일',
            onChanged: (i) => day = i + 1,
          ),
        ),
      ],
    ),
  );
}

/// 창의 틀 — 앱의 모든 창이 쓰는 [SeniorSheet] 셸 위에 굴림판만 얹는다.
Future<T?> _showPickerSheet<T>({
  required BuildContext context,
  required String title,
  required T Function() onConfirm,
  required WidgetBuilder builder,
  String? confirmLabel,
  List<Widget> extraButtons = const [],
}) {
  return SeniorSheet.show<T>(
    context: context,
    builder: (sheetContext) => SeniorSheet(
      title: title,
      trailing: Semantics(
        button: true,
        child: GestureDetector(
          onTap: () => Navigator.of(sheetContext).pop<T>(onConfirm()),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              confirmLabel ?? '확인',
              style: AppText.cardTitle(size: 23, color: AppColors.point),
            ),
          ),
        ),
      ),
      // 제목 바로 아래에 붙인다. 굴림판은 가운데가 비어 보이므로 넉넉한
      // 높이를 주되, 제목과 사이는 좁게 둔다.
      bodyGap: 4,
      body: SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.34,
        child: builder(sheetContext),
      ),
      actions: extraButtons,
    ),
  );
}

/// 굴림판 한 줄기. 가운데 칸은 쿠퍼티노 기본 회색 띠를 그대로 쓴다.
class _Wheel extends StatelessWidget {
  final int count;
  final int initialIndex;
  final String Function(int index) labelOf;
  final ValueChanged<int> onChanged;

  const _Wheel({
    required this.count,
    required this.initialIndex,
    required this.labelOf,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoPicker(
      scrollController: FixedExtentScrollController(
        initialItem: initialIndex < 0 ? 0 : initialIndex,
      ),
      itemExtent: 68,
      squeeze: 1.1,
      onSelectedItemChanged: onChanged,
      children: [
        for (int i = 0; i < count; i++)
          Center(
            child: Text(
              labelOf(i),
              style: AppText.body(size: 26, color: AppColors.textPrimary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}
