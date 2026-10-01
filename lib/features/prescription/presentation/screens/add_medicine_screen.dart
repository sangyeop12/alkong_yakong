import 'package:flutter/material.dart';
import '../../../medication/application/medication_controller.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_header.dart';

/// 어떤 방법으로 약을 넣을지.
enum AddMedicineMethod { camera, gallery, manual, family }

/// 07 · 약 넣기 · 방법 고르기.
///
/// **어두운 카메라 화면 위에 선택지를 얹지 않는다.**
/// 밝은 화면에서 고르는 일만 먼저 끝내고, 카메라는 찍기만 한다.
class AddMedicineScreen extends StatefulWidget {
  final void Function(AddMedicineMethod method) onPick;
  final String guardianTitle;

  /// 부탁을 마친 뒤 오늘 화면으로 돌아가는 길.
  final VoidCallback? onGoHome;

  /// 이미 부탁을 마치고 들어왔는지. 첫 사용 화면에서 넘어올 때 true다.
  final bool familyAsked;

  const AddMedicineScreen({
    super.key,
    required this.onPick,
    this.guardianTitle = '',
    this.onGoHome,
    this.familyAsked = false,
  });

  @override
  State<AddMedicineScreen> createState() => _AddMedicineScreenState();
}

class _AddMedicineScreenState extends State<AddMedicineScreen> {
  /// 가족에게 부탁했는지. 화면을 옮기지 않고 자리에서 카드로 바뀐다.
  late bool _asked = widget.familyAsked;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const SeniorBackHeader(title: '처방전 넣기'),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 18,
                    ),
                    // 파랑은 실제로 누르는 버튼에만 남긴다. 안내 박스까지
                    // 파랗게 두면 어느 것이 눌리는 것인지 흐려진다.
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.border, width: 2),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '어떻게 넣을까요?',
                          style: AppText.cardTitle(
                            size: 22,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '하나만 고르시면 됩니다. 나머지는 나중에도 할 수 있어요.',
                          style: AppText.body(
                            size: 17.5,
                            color: AppColors.textBody,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  // 가장 쉬운 길 하나만 파란 버튼으로 크게 둔다.
                  SeniorButton(
                    label: '처방전 사진 찍기',
                    icon: TablerIcons.camera,
                    minHeight: 68,
                    fontSize: 22,
                    elevated: true,
                    onPressed: () => widget.onPick(AddMedicineMethod.camera),
                  ),
                  const SizedBox(height: 24),
                  // 나머지 길은 한 카드에 줄로 모은다. 넷이 같은 크기로
                  // 펼쳐져 있으면 무엇을 먼저 눌러야 할지 고르게 된다.
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 4,
                    ),
                    child: Column(
                      children: [
                        SeniorListRow(
                          label: '앨범에서 고르기',
                          icon: TablerIcons.photo,
                          trailing: const SeniorChevron(),
                          onTap: () => widget.onPick(AddMedicineMethod.gallery),
                        ),
                        const SeniorDivider(),
                        SeniorListRow(
                          label: '손으로 적기',
                          icon: TablerIcons.edit,
                          trailing: const SeniorChevron(),
                          onTap: () => widget.onPick(AddMedicineMethod.manual),
                        ),
                        if (!_asked) ...[
                          const SeniorDivider(),
                          SeniorListRow(
                            label: '가족에게 부탁하기',
                            icon: TablerIcons.users,
                            trailing: const SeniorChevron(),
                            onTap: () {
                              setState(() => _asked = true);
                              widget.onPick(AddMedicineMethod.family);
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_asked) ...[
                    const SizedBox(height: 12),
                    _AskedCard(
                      guardianTitle: resolveGuardianTitle(
                        context,
                        widget.guardianTitle,
                      ),
                      onGoHome: widget.onGoHome,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 부탁하고 나면 화면을 옮기지 않고 이 카드로 바뀐다.
/// 어르신은 아무것도 더 하지 않아도 된다.
class _AskedCard extends StatelessWidget {
  final String guardianTitle;
  final VoidCallback? onGoHome;

  const _AskedCard({required this.guardianTitle, this.onGoHome});

  @override
  Widget build(BuildContext context) {
    return SeniorCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.pointTint,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const ExcludeSemantics(
                  child: Icon(
                    TablerIcons.check,
                    size: 28,
                    color: AppColors.point,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$guardianTitle에게 부탁했어요',
                      style: AppText.cardTitle(size: 21),
                    ),
                    Text(
                      '$guardianTitle이 처방전을 넣으면 '
                      '이 화면에 약이 나타납니다',
                      style: AppText.caption(size: 17.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SeniorButton(
            label: '오늘 화면으로 가기',
            kind: SeniorButtonKind.secondary,
            minHeight: 66,
            fontSize: 21,
            onPressed: onGoHome ?? () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}
