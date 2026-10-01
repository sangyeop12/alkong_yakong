import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../../core/widgets/senior_sheet.dart';
import '../../domain/easy_flow.dart';

/// 41 · 쉬운 모드 메뉴.
///
/// 흐름을 따라가다 다른 곳에 가고 싶을 때 여기서 바로 간다.
/// 한 줄로만 갈 수 있으면 그것대로 갇히기 때문에 문을 열어 둔다.
Future<EasyMenuResult?> showEasyMenuSheet(
  BuildContext context, {
  required String userName,
}) {
  return SeniorSheet.show<EasyMenuResult>(
    context: context,
    builder: (sheetContext) => SeniorSheet(
      title: '어디로 갈까요?',
      leading: Row(
        children: [
          InitialAvatar(
            name: userName,
            size: 52,
            background: AppColors.pointTint,
            foreground: AppColors.point,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$userName 님', style: AppText.cardTitle(size: 23)),
                Text('누르면 그 화면으로 바로 갑니다', style: AppText.caption(size: 17)),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int row = 0; row < (kEasyMenu.length / 2).ceil(); row++) ...[
            if (row > 0) const SizedBox(height: 10),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (int col = 0; col < 2; col++) ...[
                    if (col > 0) const SizedBox(width: 10),
                    Expanded(
                      child: row * 2 + col < kEasyMenu.length
                          ? _MenuTile(
                              destination: kEasyMenu[row * 2 + col],
                              onTap: () => Navigator.of(sheetContext).pop(
                                EasyMenuResult.go(
                                  kEasyMenu[row * 2 + col].screen,
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
      actions: [
        SeniorButton(
          label: '일반 화면으로 바꾸기',
          kind: SeniorButtonKind.neutral,
          minHeight: 62,
          fontSize: 20,
          radius: 18,
          onPressed: () =>
              Navigator.of(sheetContext).pop(const EasyMenuResult.leaveEasy()),
        ),
        SeniorButton(
          label: '닫기',
          kind: SeniorButtonKind.secondary,
          minHeight: 62,
          fontSize: 20,
          onPressed: () => Navigator.of(sheetContext).pop(),
        ),
      ],
    ),
  );
}

/// 메뉴에서 무엇을 골랐는지.
@immutable
class EasyMenuResult {
  /// 갈 화면. 일반 모드로 나가는 경우 null.
  final EasyScreen? screen;

  /// 쉬운 모드를 끄기로 했는지.
  final bool leaveEasyMode;

  const EasyMenuResult.go(EasyScreen this.screen) : leaveEasyMode = false;

  const EasyMenuResult.leaveEasy() : screen = null, leaveEasyMode = true;
}

class _MenuTile extends StatelessWidget {
  final EasyDestination destination;
  final VoidCallback onTap;

  const _MenuTile({required this.destination, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 74),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.bg,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(
            destination.label,
            textAlign: TextAlign.center,
            style: AppText.cardTitle(size: 19.5),
          ),
        ),
      ),
    );
  }
}

/// 42 · 건너뛰기 확인에서 무엇을 골랐는지.
enum SkipChoice {
  /// 먹었어요를 누르고 다음으로.
  takeAndContinue,

  /// 그냥 넘어간다.
  skip,

  /// 이 화면에 그대로 있는다.
  stay,
}

/// 42 · 건너뛰기 확인.
///
/// 흐름을 따라 다음으로 가려는데 아직 약을 안 누르셨을 때 한 번 묻는다.
/// **자동으로 "안 드셨어요"로 확정하지 않는다.**
Future<SkipChoice> showSkipConfirmSheet(
  BuildContext context, {
  required String slotLabel,
}) async {
  final choice = await SeniorSheet.show<SkipChoice>(
    context: context,
    builder: (sheetContext) => SeniorSheet(
      title: '$slotLabel 약을 아직 안 누르셨어요',
      body: const SeniorSheetBody([
        '약을 드셨으면 ',
        '먹었어요',
        '를 눌러 주세요. 아직 안 드셨으면 그냥 넘어가셔도 됩니다.',
      ]),
      actions: [
        SeniorButton(
          label: '먹었어요 · 다음으로',
          minHeight: 68,
          fontSize: 23,
          onPressed: () =>
              Navigator.of(sheetContext).pop(SkipChoice.takeAndContinue),
        ),
        SeniorButton(
          label: '그냥 넘어갈게요',
          kind: SeniorButtonKind.secondary,
          minHeight: 60,
          fontSize: 20,
          onPressed: () => Navigator.of(sheetContext).pop(SkipChoice.skip),
        ),
        SeniorButton(
          label: '이 화면에 그대로 있기',
          kind: SeniorButtonKind.neutral,
          minHeight: 62,
          fontSize: 20,
          onPressed: () => Navigator.of(sheetContext).pop(SkipChoice.stay),
        ),
      ],
    ),
  );
  return choice ?? SkipChoice.stay;
}
