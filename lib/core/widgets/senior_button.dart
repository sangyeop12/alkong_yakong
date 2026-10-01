import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../theme/app_typography.dart';

/// 버튼 종류.
///
/// 높이는 시니어 터치 실패율을 기준으로 정해진 값이라 **줄이지 않는다.**
/// 화면당 주 액션은 하나이고, 둘 이상이면 색과 크기로 위계를 나눈다.
enum SeniorButtonKind {
  /// 주 액션. 파랑 채움 + 흰 글씨. 높이 68 이상.
  primary,

  /// 보조 액션. 연한 면 + **2px 테두리**. 테두리 없는 연회색 버튼은 만들지 않는다.
  secondary,

  /// 카드 안에 들어가는 낮은 위계. "되돌리기", "30분 뒤에 다시".
  neutral,

  /// 위험 액션 — 채움. 화면당 최대 하나.
  danger,

  /// 위험 액션 — 조용한 쪽. 회색 면에 붉은 글씨. 로그아웃·연결 끊기.
  dangerQuiet,

  /// 어두운 화면(카메라) 위의 보조 액션.
  dark,

  /// 예전 화면 호환. secondary와 같다.
  outline,
}

/// 시니어 규격 버튼.
///
/// 높이는 [minHeight]로 최소값만 잡는다. 시스템 글자 크기가 200%까지 커져도
/// 라벨이 두 줄이 되며 버튼이 자랄 뿐, 글자가 잘리지 않아야 한다.
class SeniorButton extends StatefulWidget {
  final String label;

  /// 라벨 아래 두 번째 줄. 부가 설명은 회색 링크가 아니라 여기에 둔다.
  final String? subLabel;

  final VoidCallback? onPressed;
  final SeniorButtonKind kind;
  final double minHeight;
  final double fontSize;
  final double? radius;

  /// 아이콘은 항상 라벨 **왼쪽**에 둔다.
  final IconData? icon;

  /// "강조가 필요한 하나"에만 그림자를 준다.
  final bool elevated;

  const SeniorButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.subLabel,
    this.kind = SeniorButtonKind.primary,
    this.minHeight = 68,
    this.fontSize = 24,
    this.radius,
    this.icon,
    this.elevated = false,
  });

  @override
  State<SeniorButton> createState() => _SeniorButtonState();
}

class _SeniorButtonState extends State<SeniorButton> {
  bool _pressed = false;

  /// 높이 70 이상은 라운드 20, 그 아래는 18.
  double get _radius => widget.radius ?? (widget.minHeight >= 70 ? 20 : 18);

  Color get _background {
    switch (widget.kind) {
      case SeniorButtonKind.primary:
        return _pressed ? AppColors.pointPressed : AppColors.point;
      case SeniorButtonKind.danger:
        return _pressed ? AppColors.dangerPressed : AppColors.danger;
      case SeniorButtonKind.secondary:
      case SeniorButtonKind.outline:
        return _pressed ? AppColors.secondaryPressed : AppColors.secondaryFill;
      case SeniorButtonKind.neutral:
      case SeniorButtonKind.dangerQuiet:
        return _pressed ? AppColors.neutralPressed : AppColors.bg;
      case SeniorButtonKind.dark:
        return _pressed ? AppColors.darkPressed : AppColors.camChip;
    }
  }

  Color get _foreground {
    switch (widget.kind) {
      case SeniorButtonKind.primary:
      case SeniorButtonKind.danger:
        return Colors.white;
      case SeniorButtonKind.dangerQuiet:
        return AppColors.danger;
      case SeniorButtonKind.secondary:
      case SeniorButtonKind.outline:
      case SeniorButtonKind.neutral:
        return AppColors.textBody;
      case SeniorButtonKind.dark:
        return Colors.white;
    }
  }

  /// 파랑·빨강 채움 위의 두 번째 줄은 밝은 글씨로 둔다.
  Color get _subForeground {
    switch (widget.kind) {
      case SeniorButtonKind.primary:
        return AppColors.onPointMuted;
      case SeniorButtonKind.danger:
        return AppColors.dangerBorderSoft;
      case SeniorButtonKind.dark:
        return AppColors.inactive;
      default:
        return AppColors.textSecondary;
    }
  }

  BoxBorder? get _border {
    switch (widget.kind) {
      case SeniorButtonKind.secondary:
      case SeniorButtonKind.outline:
        return Border.all(color: AppColors.strongLine, width: 2);
      case SeniorButtonKind.dark:
        return Border.all(color: AppColors.onDarkBorder, width: 2);
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final label = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.label,
          textAlign: TextAlign.center,
          style: AppText.button(size: widget.fontSize, color: _foreground),
        ),
        if (widget.subLabel != null) ...[
          const SizedBox(height: 4),
          Text(
            widget.subLabel!,
            textAlign: TextAlign.center,
            style: AppText.label(size: 17, color: _subForeground),
          ),
        ],
      ],
    );

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.subLabel == null
          ? widget.label
          : '${widget.label}. ${widget.subLabel}',
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: widget.onPressed,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Container(
            width: double.infinity,
            constraints: BoxConstraints(minHeight: widget.minHeight),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _background,
              borderRadius: BorderRadius.circular(_radius),
              border: _border,
              boxShadow: widget.elevated && !_pressed
                  ? const [
                      BoxShadow(
                        color: AppColors.pointShadow,
                        blurRadius: 14,
                        offset: Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: widget.icon == null
                ? label
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ExcludeSemantics(
                        child: Icon(widget.icon, size: 27, color: _foreground),
                      ),
                      const SizedBox(width: 11),
                      Flexible(child: label),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// 큰 선택 카드 — "약 넣기 방법 고르기"처럼 갈림길을 보여줄 때 쓴다.
///
/// 아이콘이 크고(38~44) 제목 아래 설명 한 줄이 붙는다.
class SeniorChoiceCard extends StatefulWidget {
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback? onPressed;

  /// 권하는 쪽이면 파랑 채움, 아니면 연한 면 + 2px 테두리.
  final bool primary;

  const SeniorChoiceCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.onPressed,
    this.primary = false,
  });

  @override
  State<SeniorChoiceCard> createState() => _SeniorChoiceCardState();
}

class _SeniorChoiceCardState extends State<SeniorChoiceCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final primary = widget.primary;
    final bg = primary
        ? (_pressed ? AppColors.pointPressed : AppColors.point)
        : (_pressed ? AppColors.secondaryPressed : AppColors.secondaryFill);
    final fg = primary ? Colors.white : AppColors.textBody;
    final subFg = primary ? AppColors.onPointMuted : AppColors.textSecondary;

    return Semantics(
      button: true,
      label: '${widget.title}. ${widget.description}',
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(minHeight: primary ? 118 : 104),
          padding: EdgeInsets.symmetric(
            horizontal: 22,
            vertical: primary ? 18 : 16,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(22),
            border: primary
                ? null
                : Border.all(color: AppColors.strongLine, width: 2),
            boxShadow: primary && !_pressed
                ? const [
                    BoxShadow(
                      color: AppColors.pointShadow,
                      blurRadius: 14,
                      offset: Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              ExcludeSemantics(
                child: Icon(widget.icon, size: primary ? 44 : 38, color: fg),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      style: AppText.cardTitle(
                        size: primary ? 24 : 22,
                        color: fg,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.description,
                      style: AppText.label(
                        size: primary ? 17 : 16.5,
                        color: subFg,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 카드 하단의 텍스트 버튼.
///
/// **회색 텍스트 링크를 액션으로 쓰지 않는다**는 규칙 때문에 쓰임이 좁다.
/// 화면을 벗어나지 않는 보조 안내(예: "이 화면에 그대로 있기")에만 남긴다.
class SeniorTextButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final Color color;
  final double fontSize;
  final bool expand;

  const SeniorTextButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.color = AppColors.textSecondary,
    this.fontSize = 18,
    this.expand = true,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: expand ? double.infinity : null,
          constraints: const BoxConstraints(minHeight: 48),
          // alignment를 주면 Container가 주어진 폭을 꽉 채운다.
          // 가로를 채우지 않을 때는 글자 폭만 차지해야 오른쪽에 붙는다.
          alignment: expand ? Alignment.center : null,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: AppText.label(size: fontSize, color: color),
          ),
        ),
      ),
    );
  }
}
