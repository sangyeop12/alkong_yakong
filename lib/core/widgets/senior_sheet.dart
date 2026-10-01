import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../theme/app_typography.dart';

/// 바텀시트 공통 셸.
///
/// 중복 복용 차단, 처방 리필, 센서 착용 확인, 로그아웃, 쉬운 모드 메뉴,
/// 건너뛰기 확인, 돌보는 분 추가가 모두 이 셸을 쓴다.
///
/// 버튼은 **주 → 보조 → 취소** 순서로 세로로 쌓는다.
class SeniorSheet extends StatelessWidget {
  /// 27/900 제목. 시트가 무엇을 묻는지 한 문장으로.
  final String title;

  /// 19/500 본문. 강조할 말은 [SeniorSheetBody]로 굵게 만든다.
  final Widget? body;

  /// 주 → 보조 → 취소 순으로 넣는다.
  final List<Widget> actions;

  /// 제목 위에 들어가는 내용 (기록 증거 박스, 그리드 등).
  final Widget? leading;

  /// 제목 오른쪽 자리. 굴림판 창의 "확인"이 여기 붙는다.
  final Widget? trailing;

  /// 제목과 본문 사이. 굴림판처럼 본문이 넓은 창은 더 붙인다.
  final double bodyGap;

  const SeniorSheet({
    super.key,
    required this.title,
    this.body,
    this.actions = const [],
    this.leading,
    this.trailing,
    this.bodyGap = 14,
  });

  /// 스크림을 눌러 닫을 수 있는 표준 방식으로 띄운다.
  static Future<T?> show<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool dismissible = true,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      isDismissible: dismissible,
      enableDrag: dismissible,
      barrierColor: AppColors.scrim,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) =>
          _SheetHost(dismissible: dismissible, builder: builder),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        boxShadow: [
          BoxShadow(
            color: AppColors.sheetShadow,
            blurRadius: 40,
            offset: Offset(0, -12),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 52,
                  height: 5,
                  decoration: BoxDecoration(
                    color: AppColors.chartPast,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              if (leading != null) ...[leading!, const SizedBox(height: 14)],
              if (trailing == null)
                Text(title, style: AppText.emphasis(size: 27))
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: AppText.emphasis(size: 26),
                        maxLines: 2,
                      ),
                    ),
                    const SizedBox(width: 12),
                    trailing!,
                  ],
                ),
              if (body != null) ...[SizedBox(height: bodyGap), body!],
              for (final action in actions) ...[
                const SizedBox(height: 14),
                action,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 시트를 담는 자리.
///
/// 시트는 화면 위에 덮이는 창이라, 화면 쪽 스낵바를 띄우면 시트 뒤에 가려
/// 아무것도 보이지 않는다. 그래서 시트가 **자기 스낵바 자리**를 갖는다.
/// 시트 위쪽 빈 곳을 누르면 닫히는 것은 그대로다.
class _SheetHost extends StatelessWidget {
  final WidgetBuilder builder;
  final bool dismissible;

  const _SheetHost({required this.builder, required this.dismissible});

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      child: Builder(
        builder: (hostContext) => Scaffold(
          backgroundColor: Colors.transparent,
          // 자판이 올라오면 Scaffold가 먼저 짧아진다. 시트는 그 남은 키를
          // 넘지 않게 묶어 두고, 모자라면 시트 안에서 밀어 본다.
          body: LayoutBuilder(
            builder: (_, constraints) => Column(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: dismissible
                        ? () => Navigator.of(hostContext).maybePop()
                        : null,
                    child: const SizedBox.expand(),
                  ),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: constraints.maxHeight),
                  child: Builder(builder: builder),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 시트 본문. 강조할 말만 굵고 진하게 둔다.
class SeniorSheetBody extends StatelessWidget {
  /// 일반 문장과 강조 문장을 번갈아 넣는다. 홀수 번째가 강조다.
  final List<String> parts;

  const SeniorSheetBody(this.parts, {super.key});

  /// 강조 없이 한 문장만 둘 때.
  SeniorSheetBody.plain(String text, {super.key}) : parts = [text];

  @override
  Widget build(BuildContext context) {
    final base = AppText.body(size: 19, color: AppColors.textBody);
    return Text.rich(
      TextSpan(
        children: [
          for (int i = 0; i < parts.length; i++)
            TextSpan(
              text: parts[i],
              style: i.isOdd
                  ? AppText.body(
                      size: 19,
                      color: AppColors.textPrimary,
                      weight: FontWeight.w700,
                    )
                  : base,
            ),
        ],
      ),
      style: base,
    );
  }
}
