import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../domain/app_documents.dart';

/// 도움이 필요할 때 — 자주 묻는 것과 하는 방법.
///
/// 꼭지를 모두 펼쳐 두면 화면이 너무 길어져 찾는 것을 포기한다.
/// 제목만 보이고, 누르면 순서가 펼쳐진다.
class HelpScreen extends StatefulWidget {
  /// 모든 꼭지를 펼친 채로 연다. 글자 배율 검사에서 펼친 내용까지 그려 보려고 둔다.
  final bool openAll;

  const HelpScreen({super.key, this.openAll = false});

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  late final Set<int> _open = widget.openAll
      ? {for (int i = 0; i < kHelpTopics.length; i++) i}
      : <int>{};

  void _toggle(int index) {
    setState(() {
      if (!_open.remove(index)) _open.add(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const SeniorBackHeader(title: '도움이 필요할 때'),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              children: [
                Text('궁금한 것을 눌러 보세요', style: AppText.cardTitle(size: 22)),
                const SizedBox(height: 4),
                Text('누르면 하는 방법이 펼쳐져요.', style: AppText.body(size: 18)),
                const SizedBox(height: 14),
                for (int i = 0; i < kHelpTopics.length; i++) ...[
                  _TopicCard(
                    topic: kHelpTopics[i],
                    open: _open.contains(i),
                    onTap: () => _toggle(i),
                  ),
                  const SizedBox(height: 12),
                ],
                const SizedBox(height: 8),
                SeniorCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 16,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('그래도 어려우시면', style: AppText.cardTitle()),
                      const SizedBox(height: 6),
                      Text(kHelpStillStuck, style: AppText.body()),
                      const SizedBox(height: 14),
                      _NoteBox(text: kHelpMedicalNote, warning: true),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopicCard extends StatelessWidget {
  final HelpTopic topic;
  final bool open;
  final VoidCallback onTap;

  const _TopicCard({
    required this.topic,
    required this.open,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SeniorCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: open,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(22),
              child: Container(
                constraints: const BoxConstraints(minHeight: 64),
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 16,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        topic.title,
                        style: AppText.cardTitle(size: 20),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Semantics(
                      label: open ? '접기' : '펼치기',
                      child: RotatedBox(
                        quarterTurns: open ? 1 : 0,
                        child: SeniorChevron(
                          color: open ? AppColors.point : AppColors.chevron,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SeniorDivider(),
                  const SizedBox(height: 14),
                  for (int i = 0; i < topic.steps.length; i++) ...[
                    if (i > 0) const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${i + 1}.',
                          style: AppText.body(
                            color: AppColors.point,
                            weight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(topic.steps[i], style: AppText.body()),
                        ),
                      ],
                    ),
                  ],
                  if (topic.note != null) ...[
                    const SizedBox(height: 16),
                    _NoteBox(text: topic.note!, warning: topic.noteIsWarning),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 덧붙이는 말 상자. 경고면 붉은 제목을 달아 색만으로 뜻을 만들지 않는다.
class _NoteBox extends StatelessWidget {
  final String text;
  final bool warning;

  const _NoteBox({required this.text, required this.warning});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: warning ? AppColors.dangerBgSoft : AppColors.sunken,
        borderRadius: BorderRadius.circular(16),
        border: warning
            ? Border.all(color: AppColors.dangerBorder, width: 2)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (warning) ...[
            Text(
              '꼭 알아 두세요',
              style: AppText.cardTitle(size: 19, color: AppColors.danger),
            ),
            const SizedBox(height: 4),
          ],
          Text(text, style: AppText.body(size: 18)),
        ],
      ),
    );
  }
}
