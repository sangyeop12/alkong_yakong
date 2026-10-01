import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_header.dart';

/// 가족이 대신 넣어 준 약이 들어왔을 때 (프로토타입 84).
///
/// 어르신이 따로 하실 일은 없다. "알겠어요" 하나만 누르면 끝난다.
class MedicineArrivedScreen extends StatelessWidget {
  /// 넣어 준 가족 호칭 ("딸 지안").
  final String senderTitle;

  /// 새로 들어온 약. {name, dose, times}.
  final List<Map<String, String>> medicines;

  const MedicineArrivedScreen({
    super.key,
    required this.senderTitle,
    this.medicines = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const SeniorTitleHeader(title: '약이 들어왔어요'),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 20,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            InitialAvatar(
                              name: senderTitle.split(' ').last,
                              size: 60,
                              background: AppColors.pointTint,
                              foreground: AppColors.point,
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Text(
                                '$senderTitle 님이\n약을 넣어드렸어요',
                                style: AppText.emphasis(size: 25),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Text(
                          '따로 하실 일은 없어요. 약 드실 시간이 되면 소리로 알려드립니다.',
                          style: AppText.body(size: 19),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 20,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('새로 들어온 약', style: AppText.cardTitle(size: 21)),
                        const SizedBox(height: 14),
                        if (medicines.isEmpty)
                          Text(
                            '약 이름은 내 약 목록에서 보실 수 있어요.',
                            style: AppText.body(size: 18),
                          )
                        else
                          for (final medicine in medicines) ...[
                            Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    medicine['name'] ?? '',
                                    style: AppText.cardTitle(size: 21),
                                  ),
                                  if ((medicine['dose'] ?? '').isNotEmpty)
                                    Text(
                                      medicine['dose']!,
                                      style: AppText.caption(size: 17.5),
                                    ),
                                ],
                              ),
                            ),
                          ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Column(
                children: [
                  SeniorButton(
                    label: '네, 알겠어요',
                    minHeight: 74,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(height: 12),
                  SeniorButton(
                    label: '약 자세히 보기',
                    kind: SeniorButtonKind.secondary,
                    minHeight: 64,
                    fontSize: 21,
                    onPressed: () => context.push('/my-medicines'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
