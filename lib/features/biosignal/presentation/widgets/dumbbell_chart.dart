import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../domain/heart_data.dart';

/// 이번 주 전·후 막대.
///
/// **연속 선 그래프를 쓰지 않는다.** 하루에 두 번 잰 값이 전부이므로,
/// 요일마다 막대 두 개를 나란히 세워 "먹은 뒤 낮아졌다"만 보이게 한다.
class DumbbellChart extends StatelessWidget {
  final List<HeartDay> days;

  /// 막대 높이를 정하는 범위. 이 밖의 값은 잘라서 그린다.
  static const int minBpm = 50;
  static const int maxBpm = 95;

  /// 가장 높은 막대의 높이.
  static const double barArea = 118;

  const DumbbellChart({super.key, required this.days});

  double _heightFor(int? bpm) {
    if (bpm == null) return 0;
    final clamped = bpm.clamp(minBpm, maxBpm);
    return (clamped - minBpm) / (maxBpm - minBpm) * barArea;
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '이번 주 요일별로 약 먹기 전과 먹은 뒤 심박수',
      child: ExcludeSemantics(
        child: SizedBox(
          height: barArea + 32,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (int i = 0; i < days.length; i++) ...[
                if (i > 0) const SizedBox(width: 7),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _Bar(
                            height: _heightFor(days[i].pair.before),
                            color: AppColors.strongBorder,
                          ),
                          const SizedBox(width: 3),
                          _Bar(
                            height: _heightFor(days[i].pair.after),
                            color: AppColors.point,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        days[i].weekday,
                        style: AppText.cardTitle(
                          size: 16,
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  final double height;
  final Color color;

  const _Bar({required this.height, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
      ),
    );
  }
}

/// 막대 색이 무엇을 뜻하는지 알려주는 범례.
class DumbbellLegend extends StatelessWidget {
  const DumbbellLegend({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: const [
        _LegendDot(color: AppColors.strongBorder, label: '전'),
        SizedBox(width: 12),
        _LegendDot(color: AppColors.point, label: '후'),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: AppText.caption(size: 17)),
      ],
    );
  }
}
