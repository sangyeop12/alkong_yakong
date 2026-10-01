import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_sheet.dart';

/// "먹었어요"를 누른 뒤 어디로 갈지.
enum WearChoice {
  /// 띠를 차고 있다 — 복약을 기록하고 심박수를 잰다.
  wearingAndMeasure,

  /// 안 차고 있다 — 복약만 기록한다.
  recordOnly,

  /// 그만두기 — 아무것도 기록하지 않는다.
  cancel,
}

/// 13 · 심박 센서 차고 계신가요.
///
/// "먹었어요"를 누르면 **항상** 이것이 먼저 뜬다. 바로 기록하지 않는다.
/// 센서를 차고 계시면 약 드신 뒤 심박수를 한 번 재는 것이 이 앱의 핵심이라,
/// 그 기회를 놓치지 않으려고 매번 묻는다.
Future<WearChoice> showWearSensorSheet(BuildContext context) async {
  final choice = await SeniorSheet.show<WearChoice>(
    context: context,
    builder: (sheetContext) => SeniorSheet(
      title: '심박 센서를 차고 계신가요?',
      body: const SeniorSheetBody([
        '차고 계시면 약을 드신 뒤 ',
        '심박수를 한 번 측정해 드립니다.',
        ' 안 차고 계셔도 복약은 그대로 기록돼요.',
      ]),
      actions: [
        SeniorButton(
          label: '차고 있어요 · 측정',
          icon: TablerIcons.activity_heartbeat,
          minHeight: 74,
          fontSize: 24,
          elevated: true,
          onPressed: () =>
              Navigator.of(sheetContext).pop(WearChoice.wearingAndMeasure),
        ),
        SeniorButton(
          label: '안 차고 있어요 · 복약만 기록',
          kind: SeniorButtonKind.secondary,
          minHeight: 66,
          fontSize: 20,
          onPressed: () =>
              Navigator.of(sheetContext).pop(WearChoice.recordOnly),
        ),
        SeniorButton(
          label: '그만두기',
          kind: SeniorButtonKind.neutral,
          minHeight: 62,
          fontSize: 20,
          onPressed: () => Navigator.of(sheetContext).pop(WearChoice.cancel),
        ),
      ],
    ),
  );
  return choice ?? WearChoice.cancel;
}

/// 처방이 끝날 때 무엇을 할지.
enum RefillChoice {
  /// 새 처방전을 사진으로 등록한다.
  addPrescription,

  /// 아직 못 받았다 — 가족에게 알린다.
  tellFamily,

  /// 내일 다시 물어봐 달라.
  askTomorrow,
}

/// 17 · 처방이 오늘로 끝나요.
///
/// 잔여일이 0이 되면 홈에서 **자동으로** 열린다. 하루에 한 번만.
/// 약이 떨어진 것을 어르신이 스스로 알아채기를 기대하지 않는다.
Future<RefillChoice> showRefillSheet(
  BuildContext context, {
  required String startedOn,
  required int totalDays,
}) async {
  final choice = await SeniorSheet.show<RefillChoice>(
    context: context,
    builder: (sheetContext) => SeniorSheet(
      title: '처방이 오늘로 끝나요',
      body: SeniorSheetBody([
        '$startedOn에 받으신 ',
        '$totalDays일치',
        '가 오늘까지예요. 새 처방전을 사진으로 등록하시면 '
            '약 이름과 시간을 ',
        '자동으로 읽어',
        ' 드려요.',
      ]),
      actions: [
        SeniorButton(
          label: '새 처방전 등록',
          subLabel: '사진 한 장이면 됩니다',
          icon: TablerIcons.camera,
          minHeight: 78,
          fontSize: 24,
          elevated: true,
          onPressed: () =>
              Navigator.of(sheetContext).pop(RefillChoice.addPrescription),
        ),
        SeniorButton(
          label: '아직 못 받았어요 · 가족에게 알리기',
          kind: SeniorButtonKind.secondary,
          minHeight: 60,
          fontSize: 19,
          onPressed: () =>
              Navigator.of(sheetContext).pop(RefillChoice.tellFamily),
        ),
        SeniorButton(
          label: '내일 다시 물어봐 주세요',
          kind: SeniorButtonKind.neutral,
          minHeight: 62,
          fontSize: 20,
          onPressed: () =>
              Navigator.of(sheetContext).pop(RefillChoice.askTomorrow),
        ),
      ],
    ),
  );
  return choice ?? RefillChoice.askTomorrow;
}

/// 잔여일을 색으로 말한다. 0일이면 붉어지고 문구도 바뀐다.
Color daysLeftColor(int daysLeft) {
  if (daysLeft == 0) return AppColors.danger;
  if (daysLeft <= 3) return AppColors.textBody;
  return AppColors.textTertiary;
}

/// 홈 카드 맨 위의 잔여일 행.
class DaysLeftRow extends StatelessWidget {
  final int daysLeft;
  final String phrase;
  final VoidCallback? onTap;

  const DaysLeftRow({
    super.key,
    required this.daysLeft,
    required this.phrase,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = daysLeftColor(daysLeft);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            ExcludeSemantics(
              child: Icon(TablerIcons.calendar_repeat, size: 22, color: color),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                phrase,
                style: AppText.label(size: 17.5, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
