import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../domain/app_documents.dart';

/// 알려드릴 소식.
///
/// 공지를 내려주는 서버가 아직 없다. 지어낸 소식을 채우지 않고,
/// 지금 버전과 "소식이 생기면 알려드린다"는 빈 상태만 보여준다.
class NoticesScreen extends StatelessWidget {
  const NoticesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const SeniorBackHeader(title: '알려드릴 소식'),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 28,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '아직 새 소식이 없어요',
                          textAlign: TextAlign.center,
                          style: AppText.emphasis(size: 23),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '새로운 소식이 생기면 여기에 알려드릴게요.',
                          textAlign: TextAlign.center,
                          style: AppText.body(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 16,
                    ),
                    child: LabelValueRow(
                      label: Text('지금 쓰시는 버전', style: AppText.label(size: 19)),
                      value: Text(
                        '알콩약콩 $kAppVersion',
                        textAlign: TextAlign.right,
                        style: AppText.cardTitle(),
                      ),
                    ),
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
