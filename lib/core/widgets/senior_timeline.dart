import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

/// 왼쪽 축 + 오른쪽 카드.
///
/// 하루를 위에서 아래로 흐르는 시간 축으로 그린다. 점 세 개짜리 진행 표시를
/// 어르신은 진행 상태로 읽지 못한다. 축 위에 올려 두면 **"지금 할 일"이
/// 딱 하나 굵게** 남는다.
///
/// 홈과 기록 화면이 같이 쓴다.
class TimelineRow extends StatelessWidget {
  final Widget child;

  /// 지금 할 일이면 true — 점이 커지고 카드에 3px 파란 테두리가 생긴다.
  final bool current;

  /// 지나간 일(파란 점) / 앞으로 올 일(회색 점).
  final bool past;

  /// 마지막 행이면 아래로 내려가는 선을 그리지 않는다.
  final bool last;

  /// 첫 행이면 위로 올라가는 선을 그리지 않는다.
  final bool first;

  const TimelineRow({
    super.key,
    required this.child,
    this.current = false,
    this.past = false,
    this.last = false,
    this.first = false,
  });

  /// "지금" 점을 감싸는 연파랑 링.
  static const Color _currentRing = AppColors.timelineRing;

  @override
  Widget build(BuildContext context) {
    final dotColor = (current || past) ? AppColors.point : AppColors.chartPast;
    // 점은 카드의 세로 한가운데. 선은 그 위아래로 이어 붙인다.
    const line = Center(
      child: SizedBox(
        width: 3,
        height: double.infinity,
        child: ColoredBox(color: AppColors.chartPast),
      ),
    );
    // 축선이 카드 높이만큼 늘어나야 한다. 스크롤 안에서는 높이가 무한이라
    // stretch 만으로는 안 되고 IntrinsicHeight 로 카드 키를 먼저 재야 한다.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 16,
            child: Column(
              children: [
                Expanded(child: first ? const SizedBox.shrink() : line),
                // 지금: 20px 점 + 4px 연파랑 링 / 그 외: 14px 점
                Container(
                  width: current ? 20 : 14,
                  height: current ? 20 : 14,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                    border: current
                        ? Border.all(color: _currentRing, width: 4)
                        : null,
                  ),
                ),
                Expanded(child: last ? const SizedBox.shrink() : line),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// 타임라인 행 사이 간격.
const SizedBox kTimelineGap = SizedBox(height: 12);
