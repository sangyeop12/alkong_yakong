import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import 'app_typography.dart';

/// 앱 전역 테마.
///
/// 시니어 리디자인의 두 가지 전역 규칙이 여기에 있다.
/// 1. 본문 최소 18px — [TextTheme]의 어떤 항목도 16px 아래로 내려가지 않는다.
/// 2. 시스템 글자 크기를 그대로 따른다 — 앱 안에 글자 크기 설정을 두지 않는다.
abstract final class AppTheme {
  static ThemeData build() {
    const scheme = ColorScheme.light(
      primary: AppColors.point,
      onPrimary: Colors.white,
      secondary: AppColors.point,
      onSecondary: Colors.white,
      error: AppColors.danger,
      onError: Colors.white,
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.bg,
      fontFamily: AppText.fontFamily,
      fontFamilyFallback: AppText.fontFallback,
      splashFactory: InkRipple.splashFactory,
      dividerColor: AppColors.divider,
      textTheme: _textTheme,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.headerBg,
        foregroundColor: AppColors.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      // 기본 터치 타깃을 48×48 이상으로 잠근다.
      materialTapTargetSize: MaterialTapTargetSize.padded,
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.textPrimary,
        behavior: SnackBarBehavior.floating,
        contentTextStyle: AppText.body(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        titleTextStyle: AppText.cardTitle(size: 21),
        contentTextStyle: AppText.body(),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        ),
      ),
    );
  }

  static final TextTheme _textTheme = TextTheme(
    displayLarge: AppText.hero(),
    displayMedium: AppText.hero(size: 44),
    displaySmall: AppText.bigTime(),
    headlineLarge: AppText.screenTitle(),
    headlineMedium: AppText.screenTitle(size: 24),
    headlineSmall: AppText.emphasis(),
    titleLarge: AppText.cardTitle(size: 21),
    titleMedium: AppText.cardTitle(),
    titleSmall: AppText.label(),
    bodyLarge: AppText.body(),
    bodyMedium: AppText.body(),
    bodySmall: AppText.caption(),
    labelLarge: AppText.button(color: AppColors.textPrimary),
    labelMedium: AppText.label(),
    labelSmall: AppText.caption(size: 17),
  );
}
