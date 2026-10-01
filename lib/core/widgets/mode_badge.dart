import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/app_colors.dart';
import '../mode/app_mode.dart';
import '../theme/app_typography.dart';

/// 헤더 오른쪽의 모드 배지.
///
/// 오늘 · 기록 · 내 정보 세 탭 헤더에 모두 있다. 누르면 모드가 바뀐다.
/// 배지가 **지금 어느 화면인지**를 말하고, 누르면 반대쪽으로 간다.
class ModeBadge extends ConsumerWidget {
  const ModeBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final easy = ref.watch(appModeProvider).isEasy;
    return Semantics(
      button: true,
      label: easy ? '쉬운 화면. 누르면 일반 화면으로 바뀝니다' : '일반 화면. 누르면 쉬운 화면으로 바뀝니다',
      child: GestureDetector(
        onTap: () => ref.read(appModeProvider.notifier).toggle(),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            color: easy ? AppColors.point : AppColors.bg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: easy ? AppColors.pointBorder : AppColors.border,
              width: 2,
            ),
          ),
          child: Text(
            easy ? '쉬운 화면' : '일반 화면',
            style: AppText.cardTitle(
              size: 16,
              color: easy ? Colors.white : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
