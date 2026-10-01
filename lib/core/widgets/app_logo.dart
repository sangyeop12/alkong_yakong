import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

/// 앱 로고 — 말풍선 안의 알약.
///
/// 런처 아이콘과 같은 파일(`assets/icon/app_icon.png`)을 쓴다.
/// 아이콘을 바꾸면 이 자리도 함께 바뀐다.
class AppLogo extends StatelessWidget {
  final double size;

  /// 모서리 반경. 기본은 아이콘 원본의 비율(약 22%)을 따른다.
  final double? radius;

  const AppLogo({super.key, required this.size, this.radius});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius ?? size * 0.22),
      child: Image.asset(
        'assets/icon/app_icon.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        // 이미지를 못 읽어도 화면이 비지 않도록 포인트색 블록으로 대체한다.
        errorBuilder: (context, error, stackTrace) =>
            Container(width: size, height: size, color: AppColors.point),
      ),
    );
  }
}
