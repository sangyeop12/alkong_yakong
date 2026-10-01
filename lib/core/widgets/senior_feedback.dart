import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import '../constants/app_colors.dart';
import '../theme/app_typography.dart';
import 'senior_button.dart';
import 'senior_sheet.dart';

/// 예 / 아니요를 세로로 묻는 상태 안내창.
Future<bool> showSeniorYesNoDialog({
  required BuildContext context,
  required String title,
  String? message,
  String yesLabel = '예',
  String noLabel = '아니요',
}) async {
  final confirmed = await SeniorSheet.show<bool>(
    context: context,
    builder: (sheetContext) => SeniorSheet(
      title: title,
      body: (message == null || message.isEmpty)
          ? null
          : Text(message, style: AppText.body()),
      actions: [
        SeniorButton(
          label: yesLabel,
          minHeight: 66,
          fontSize: 22,
          onPressed: () => Navigator.of(sheetContext).pop(true),
        ),
        SeniorButton(
          label: noLabel,
          kind: SeniorButtonKind.secondary,
          minHeight: 62,
          fontSize: 21,
          onPressed: () => Navigator.of(sheetContext).pop(false),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// 스낵바.
///
/// **보호자에게 연락한 결과는 이것으로만 알린다.** 어르신 화면에는 전화 걸기
/// 버튼을 두지 않고, 앱이 대신 보낸 뒤 여기서 "보냈어요"라고 말해 준다.
///
/// 입력이 틀렸거나 요청이 실패한 것도 [error]로 여기서 알린다. 화면 안에
/// 오류 박스를 끼워 넣으면 버튼 위에 붙어 버튼을 밀어낸다.
///
/// 화면 아래에 고정된 버튼이 있으면 그 높이를 [bottom]으로 넘겨 가리지 않게 한다.
void showSeniorSnackbar(
  BuildContext context,
  String message, {
  bool error = false,
  double bottom = 0,
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      backgroundColor: AppColors.snackbarBg,
      elevation: 0,
      behavior: SnackBarBehavior.floating,
      margin: EdgeInsets.fromLTRB(16, 0, 16, 26 + bottom),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 17),
      duration: const Duration(seconds: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      content: Row(
        children: [
          ExcludeSemantics(
            child: Icon(
              error
                  ? TablerIcons.alert_circle_filled
                  : TablerIcons.circle_check_filled,
              size: 24,
              color: error ? AppColors.dangerBorder : AppColors.snackbarCheck,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Text(
              message,
              style: AppText.label(size: 18.5, color: Colors.white),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 세그먼트 컨트롤 — 이번 주 / 한 달, 일반 / 쉬운 화면.
class SeniorSegmented extends StatelessWidget {
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  const SeniorSegmented({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          for (int i = 0; i < labels.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: Semantics(
                button: true,
                selected: i == index,
                child: GestureDetector(
                  onTap: () => onChanged(i),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 54),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: i == index ? AppColors.point : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      labels[i],
                      textAlign: TextAlign.center,
                      style: AppText.cardTitle(
                        size: 18.5,
                        color: i == index
                            ? Colors.white
                            : AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 번호를 붙인 안내 단계. **항상 3단계 이내.**
///
/// 회복 절차, 측정 안내, 센서 착용법에 쓴다.
class NumberedSteps extends StatelessWidget {
  final List<String> steps;

  /// 위험 맥락이면 번호 원이 붉어진다.
  final bool danger;

  /// 카드 안에 넣을 때는 회색 블록으로 감싼다.
  final bool boxed;

  const NumberedSteps({
    super.key,
    required this.steps,
    this.danger = false,
    this.boxed = true,
  });

  @override
  Widget build(BuildContext context) {
    assert(steps.length <= 3, '지시는 3단계 이내로 둔다');
    final color = danger ? AppColors.danger : AppColors.point;

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < steps.length; i++) ...[
          if (i > 0) const SizedBox(height: 11),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Text(
                  '${i + 1}',
                  style: AppText.cardTitle(size: 16, color: Colors.white),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    steps[i],
                    style: AppText.label(
                      size: 18.5,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );

    if (!boxed) return column;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(18),
      ),
      child: column,
    );
  }
}

/// 입력 필드. 라벨은 필드 위에 둔다.
class SeniorField extends StatelessWidget {
  final String? label;
  final TextEditingController controller;
  final String? hint;
  final TextInputType? keyboardType;
  final bool obscure;
  final Widget? suffix;
  final ValueChanged<String>? onChanged;

  /// 글자를 다듬는 규칙. 휴대폰 번호 하이픈 같은 것.
  final List<TextInputFormatter>? inputFormatters;

  /// 자판의 "완료"를 눌렀을 때.
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;

  /// 오류가 있으면 테두리가 붉어진다.
  final bool hasError;

  const SeniorField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.keyboardType,
    this.obscure = false,
    this.suffix,
    this.onChanged,
    this.inputFormatters,
    this.onSubmitted,
    this.textInputAction,
    this.hasError = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Text(label!, style: AppText.label(size: 18)),
          const SizedBox(height: 8),
        ],
        Container(
          constraints: const BoxConstraints(minHeight: 66),
          decoration: BoxDecoration(
            color: AppColors.sunken,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: hasError ? AppColors.danger : AppColors.strongLine,
              width: 2,
            ),
          ),
          padding: EdgeInsets.only(left: 20, right: suffix == null ? 20 : 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  obscureText: obscure,
                  keyboardType: keyboardType,
                  inputFormatters: inputFormatters,
                  textInputAction: textInputAction,
                  onSubmitted: onSubmitted,
                  onChanged: onChanged,
                  style: AppText.label(size: 21, color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    hintText: hint,
                    hintStyle: AppText.label(
                      size: 21,
                      color: AppColors.chevron,
                    ),
                  ),
                ),
              ),
              ?suffix,
            ],
          ),
        ),
      ],
    );
  }
}
