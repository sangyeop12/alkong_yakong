import 'package:flutter/material.dart';

import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../profile/presentation/screens/help_screen.dart';
import '../../../profile/presentation/screens/notices_screen.dart';
import '../../../profile/presentation/screens/policy_screen.dart';

/// 내 정보 탭의 도움말·약관 목록.
///
/// 아이콘 단독 사용을 금지했으므로 아이콘을 걷어내고 한글 라벨만 남겼다.
/// 행 높이는 상하 패딩 17px로 최소 56px를 넘긴다.
class SettingsMenu extends StatelessWidget {
  const SettingsMenu({super.key});

  @override
  Widget build(BuildContext context) {
    final items = <(String, WidgetBuilder)>[
      ('도움이 필요할 때', (_) => const HelpScreen()),
      ('알려드릴 소식', (_) => const NoticesScreen()),
      ('이용약관', (_) => const PolicyScreen.terms()),
      ('개인정보처리방침', (_) => const PolicyScreen.privacy()),
    ];

    return SeniorCard(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 4),
      child: Column(
        children: [
          for (int i = 0; i < items.length; i++) ...[
            if (i > 0) const SeniorDivider(),
            SeniorListRow(
              label: items[i].$1,
              trailing: const SeniorChevron(),
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: items[i].$2)),
            ),
          ],
        ],
      ),
    );
  }
}
