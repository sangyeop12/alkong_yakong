import 'package:flutter/material.dart';

import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_sheet.dart';

/// 35 · 로그아웃 확인 시트.
///
/// **안전한 쪽이 주 버튼이다.** 실수로 큰 파란 버튼을 눌러도
/// 잃는 것이 없어야 한다. 로그아웃은 조용한 회색 버튼에 붉은 글씨로 둔다.
///
/// true를 돌려주면 로그아웃한다.
Future<bool> showLogoutSheet(BuildContext context) async {
  final result = await SeniorSheet.show<bool>(
    context: context,
    builder: (sheetContext) => SeniorSheet(
      title: '로그아웃 하시겠어요?',
      body: const SeniorSheetBody([
        '로그아웃하면 ',
        '약 알림이 오지 않습니다.',
        ' 다시 들어오려면 전화번호와 비밀번호가 필요해요.',
      ]),
      actions: [
        SeniorButton(
          label: '그대로 쓸게요',
          minHeight: 68,
          fontSize: 23,
          onPressed: () => Navigator.of(sheetContext).pop(false),
        ),
        SeniorButton(
          label: '로그아웃',
          kind: SeniorButtonKind.dangerQuiet,
          minHeight: 60,
          fontSize: 20,
          onPressed: () => Navigator.of(sheetContext).pop(true),
        ),
      ],
    ),
  );
  return result ?? false;
}
