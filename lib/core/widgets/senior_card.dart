import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import '../constants/app_colors.dart';
import '../theme/app_typography.dart';

/// 카드. **그림자를 쓰지 않는다** — 배경색([AppColors.bg]) 대비로 분리한다.
/// 강조가 필요한 카드만 3px 포인트/위험색 테두리를 두른다.
/// 색 카드가 뒤에 한 장 더 깔린 카드.
///
/// 왼쪽으로 조금 삐져나온 둥근 네모가 "여기부터 보라"고 말한다.
/// 일자 막대가 아니라 모서리가 같이 둥글어야 한 장이 겹친 것으로 보인다.
class AccentCard extends StatelessWidget {
  final Widget child;
  final Color accent;
  final Color color;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// 뒤 카드가 왼쪽으로 내다보이는 너비 — 색 띠의 두께.
  final double peek;

  const AccentCard({
    super.key,
    required this.child,
    required this.accent,
    this.color = AppColors.surface,
    this.padding = const EdgeInsets.fromLTRB(20, 18, 20, 18),
    this.radius = 22,
    this.peek = 4,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: accent,
        borderRadius: BorderRadius.circular(radius),
      ),
      padding: EdgeInsets.only(left: peek),
      child: Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: child,
      ),
    );
  }
}

class SeniorCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  final Color? borderColor;
  final double borderWidth;
  final double radius;
  final VoidCallback? onTap;

  const SeniorCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(20, 16, 20, 16),
    this.color = AppColors.surface,
    this.borderColor,
    this.borderWidth = 3,
    this.radius = 22,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final decorated = Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
        border: borderColor == null
            ? null
            : Border.all(color: borderColor!, width: borderWidth),
      ),
      child: child,
    );

    if (onTap == null) return decorated;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: decorated,
      ),
    );
  }
}

/// 카드 안 구분선. 리스트 행 사이에만 쓴다.
class SeniorDivider extends StatelessWidget {
  const SeniorDivider({super.key});

  @override
  Widget build(BuildContext context) =>
      const Divider(height: 1, thickness: 1, color: AppColors.divider);
}

/// 라벨 행 앞의 작은 원 (● 지금 드실 약).
class Dot extends StatelessWidget {
  final double size;
  final Color color;
  const Dot({super.key, this.size = 10, this.color = AppColors.point});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// 아이콘을 앞에 붙인 제목.
///
/// 아이콘은 Tabler 세트를 쓴다 — 로고와 같은 둥근 선 조형이고,
/// 시스템 이모지와 달리 기기마다 그림체가 달라지지 않는다.
///
/// **아이콘 단독으로 뜻을 만들지 않는다.** 한글 라벨이 항상 함께 있고,
/// 아이콘은 스크린리더에서 제외해 두 번 읽히지 않게 한다.
class IconTitle extends StatelessWidget {
  final IconData icon;
  final String text;
  final TextStyle style;

  /// 아이콘 색. 기본은 무채색이고, 상태를 알리는 자리에서만 색을 준다.
  final Color color;

  const IconTitle({
    super.key,
    required this.icon,
    required this.text,
    required this.style,
    this.color = AppColors.textSecondary,
  });

  @override
  Widget build(BuildContext context) {
    final size = (style.fontSize ?? 20) * 1.15;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Icon(icon, size: size, color: color),
        ),
        const SizedBox(width: 9),
        Expanded(child: Text(text, style: style)),
      ],
    );
  }
}

/// 상태 배지 ("꼭 확인하세요", "정상이에요", "가장 쉬운 방법").
class SeniorBadge extends StatelessWidget {
  final String label;
  final Color background;
  final Color foreground;
  final double radius;
  final double fontSize;
  final EdgeInsetsGeometry padding;

  const SeniorBadge({
    super.key,
    required this.label,
    this.background = AppColors.pointTint,
    this.foreground = AppColors.point,
    this.radius = 12,
    this.fontSize = 19,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Text(
        label,
        style: AppText.cardTitle(size: fontSize, color: foreground),
      ),
    );
  }
}

/// 설정·목록 행. 라벨 20px/700 + 값 18px/700 + `›`.
/// 행 높이는 패딩 17px 상하로 최소 56px를 넘긴다.
class SeniorListRow extends StatelessWidget {
  final String label;
  final String? value;
  final Color valueColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 라벨 앞에 붙는 아이콘. 없으면 라벨만 그린다.
  final IconData? icon;

  /// 아이콘 색.
  final Color iconColor;

  /// 라벨 아래 한 줄. 라벨이 길어 값이 옆에 들어가기 어려울 때 쓴다.
  final String? subtitle;

  /// 부제 색. 상태값이면 포인트색을 준다.
  final Color subtitleColor;

  /// 라벨 색. 로그아웃처럼 눈에 덜 띄어야 하는 행에서만 낮춘다.
  final Color labelColor;

  const SeniorListRow({
    super.key,
    required this.label,
    this.value,
    this.valueColor = AppColors.textTertiary,
    this.trailing,
    this.onTap,
    this.icon,
    this.iconColor = AppColors.textSecondary,
    this.subtitle,
    this.subtitleColor = AppColors.textTertiary,
    this.labelColor = AppColors.textPrimary,
  });

  @override
  Widget build(BuildContext context) {
    // 글씨를 크게 키운 기기에서는 값을 라벨 아래로 내린다.
    // 한 줄에 억지로 붙이면 "1건"이 두 줄로 쪼개진다.
    final stacked = MediaQuery.textScalerOf(context).scale(18) > 26;
    final valueText = value == null
        ? null
        : Text(
            value!,
            textAlign: stacked ? TextAlign.left : TextAlign.right,
            style: AppText.label(size: 18, color: valueColor),
          );

    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(vertical: 17),
        child: Row(
          children: [
            if (icon != null) ...[
              ExcludeSemantics(child: Icon(icon, size: 24, color: iconColor)),
              const SizedBox(width: 13),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: AppText.label(
                      size: 20,
                      color: labelColor,
                      weight: FontWeight.w700,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: AppText.caption(size: 17, color: subtitleColor),
                    ),
                  if (stacked && valueText != null) ...[
                    const SizedBox(height: 4),
                    valueText,
                  ],
                ],
              ),
            ),
            // 값은 오른쪽 끝에 붙인다. Flexible로 두면 라벨과 남은 폭을
            // 반씩 나눠 가져서 값이 화면 한가운데로 밀려난다.
            // 폭 상한만 걸어 두면 아주 긴 값도 넘치지 않고 줄바꿈한다.
            if (!stacked && valueText != null) ...[
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width * 0.45,
                ),
                child: valueText,
              ),
            ],
            if (trailing != null) ...[const SizedBox(width: 10), trailing!],
          ],
        ),
      ),
    );
  }
}

/// 56×32 토글. 스위치 단독으로 의미를 만들지 않고 항상 한글 설명과 함께 둔다.
class SeniorToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String semanticLabel;

  const SeniorToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel = '켜기 끄기',
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      label: semanticLabel,
      child: GestureDetector(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: Container(
          width: 56,
          height: 48,
          alignment: Alignment.center,
          color: Colors.transparent,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 56,
            height: 32,
            padding: const EdgeInsets.all(3),
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            decoration: BoxDecoration(
              color: value ? AppColors.point : AppColors.strongBorder,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Container(
              width: 26,
              height: 26,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 라벨과 값을 한 줄에 두되, **글자가 커지면 두 줄로 접는다.**
///
/// 시스템 글자 크기를 최대로 올려도 값이 잘리지 않아야 한다는 요건 때문에,
/// 가로 배치를 고집하지 않고 배율이 커지면 세로로 전환한다.
class LabelValueRow extends StatelessWidget {
  final Widget label;
  final Widget value;

  const LabelValueRow({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scaled = MediaQuery.textScalerOf(context).scale(18);
    if (scaled > 26) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [label, const SizedBox(height: 6), value],
      );
    }
    // 값은 제 너비만 쓰고 오른쪽 끝에 붙는다. Flexible을 주면 라벨과
    // 남은 폭을 반씩 나눠 가져서 값이 가운데로 밀려난다.
    // 폭 상한만 걸어 두면 긴 값도 넘치지 않고 줄바꿈한다.
    return Row(
      children: [
        Expanded(child: label),
        const SizedBox(width: 12),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.55,
          ),
          child: value,
        ),
      ],
    );
  }
}

/// 약 사진 자리. 사진이 붙기 전까지는 알약 아이콘으로 둔다.
///
/// 홈 카드와 내 약 목록이 **같은 생김새**를 써야 같은 약으로 읽힌다.
class PillPhoto extends StatelessWidget {
  final double size;

  const PillPhoto({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.bg,
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.border, width: 2),
        ),
        child: Icon(
          TablerIcons.pill,
          size: size * 0.45,
          color: AppColors.inactive,
        ),
      ),
    );
  }
}
