import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../theme/app_typography.dart';

/// 하단 탭 하나. **아이콘 단독 사용은 금지** — 라벨은 항상 함께 그린다.
class SeniorNavItem {
  final IconData icon;
  final String label;
  const SeniorNavItem({required this.icon, required this.label});
}

/// 하단 탭 바.
/// 환자: 오늘 · 기록 · 내 정보 / 보호자: 현황 · 알림 · 내 정보.
/// 역할 구분은 색이 아니라 이 라벨로 한다.
class SeniorBottomNav extends StatelessWidget {
  final List<SeniorNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  const SeniorBottomNav({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.headerBg,
        border: Border(top: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 12),
          child: Row(
            children: [
              for (int i = 0; i < items.length; i++)
                Expanded(
                  child: _NavCell(
                    item: items[i],
                    active: i == currentIndex,
                    onTap: () => onTap(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavCell extends StatelessWidget {
  final SeniorNavItem item;
  final bool active;
  final VoidCallback onTap;

  const _NavCell({
    required this.item,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      label: item.label,
      child: InkResponse(
        onTap: onTap,
        radius: 56,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                item.icon,
                size: 28,
                color: active ? AppColors.point : AppColors.inactive,
              ),
              const SizedBox(height: 5),
              Text(
                item.label,
                textAlign: TextAlign.center,
                style: AppText.tab(active: active),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
