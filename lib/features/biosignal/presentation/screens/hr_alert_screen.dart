import 'package:flutter/material.dart';
import '../../../medication/application/medication_controller.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_feedback.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../medication/domain/medication_models.dart';
import 'saved_screen.dart';

/// 29 · 심박수 이상.
///
/// 숫자보다 **지금 무엇을 할지**를 먼저 보여준다.
/// 보호자에게는 이미 연락이 간 상태로 시작한다 — 어르신이 전화를 걸 필요가 없다.
class HrAlertScreen extends StatefulWidget {
  final int bpm;
  final String guardianTitle;

  /// 잰 시각. 없으면 이 화면을 여는 지금 시각을 쓴다.
  final DateTime? measuredAt;

  /// 이 분의 평소 범위(예: "68~78회"). 서버가 알려준 값만 넘긴다.
  /// 없으면 "평소"를 지어 말하지 않고 앱의 기준 수치와 비교해 말한다.
  final String? usualRange;

  const HrAlertScreen({
    super.key,
    required this.bpm,
    this.guardianTitle = '',
    this.measuredAt,
    this.usualRange,
  });

  @override
  State<HrAlertScreen> createState() => _HrAlertScreenState();
}

class _HrAlertScreenState extends State<HrAlertScreen> {
  /// 화면을 연 순간을 한 번만 잡는다. 다시 그릴 때마다 시각이 흐르면 안 된다.
  late final DateTime _measuredAt = widget.measuredAt ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    // 화면에 들어오는 순간 이미 보호자에게 갔다는 사실을 알린다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        showSeniorSnackbar(
          context,
          '${resolveGuardianTitle(context, widget.guardianTitle)}에게 연락이 갔어요',
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          SeniorHeader(
            background: AppColors.dangerHeaderBg,
            borderColor: AppColors.dangerHeaderBorder,
            child: Row(
              children: [
                const SeniorBackButton(),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    '심박수 이상',
                    style: AppText.screenTitle(
                      size: 24,
                      color: AppColors.danger,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              // 아래 스낵바가 가리지 않도록 넉넉히 띄운다.
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 118),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ValueCard(
                    bpm: widget.bpm,
                    measuredAt: '오늘 ${DoseSlot.absoluteTime(_measuredAt)}',
                    usualRange: widget.usualRange,
                  ),
                  const SizedBox(height: 12),
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 18,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('지금 이렇게 해주세요', style: AppText.cardTitle(size: 20)),
                        const SizedBox(height: 14),
                        const NumberedSteps(
                          boxed: false,
                          danger: true,
                          steps: [
                            '하던 일을 멈추고 앉거나 누우세요',
                            '숨을 천천히 크게 쉬세요',
                            '가슴이 아프거나 숨이 차면 119에 알리세요',
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  SeniorButton(
                    label: '지금은 괜찮아졌어요',
                    subLabel: '기록 남기기',
                    icon: TablerIcons.circle_check,
                    minHeight: 80,
                    fontSize: 23,
                    elevated: true,
                    onPressed: () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (_) => SavedScreen(
                          bpm: widget.bpm,
                          guardianTitle: resolveGuardianTitle(
                            context,
                            widget.guardianTitle,
                          ),
                          fromAlert: true,
                          savedAt: DateTime.now(),
                        ),
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

class _ValueCard extends StatelessWidget {
  final int bpm;
  final String measuredAt;
  final String? usualRange;

  const _ValueCard({
    required this.bpm,
    required this.measuredAt,
    required this.usualRange,
  });

  /// 안정 상태에서 이 수치를 넘으면 빠른 것으로 본다.
  static const int _fastBpm = 80;

  @override
  Widget build(BuildContext context) {
    final usualRange = this.usualRange;
    final hasUsual = usualRange != null && usualRange.isNotEmpty;
    // 평소 범위를 모르면 이 기준과 비교해 말한다.
    final headline = hasUsual ? '평소보다 빠릅니다' : '기준($_fastBpm회)보다 빠릅니다';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.all(Radius.circular(22)),
        border: Border(left: BorderSide(color: AppColors.danger, width: 6)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const ExcludeSemantics(
                child: Icon(
                  TablerIcons.activity_heartbeat,
                  size: 26,
                  color: AppColors.danger,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '방금 측정한 심박수',
                  style: AppText.cardTitle(size: 19, color: AppColors.danger),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Semantics(
            label: '방금 측정한 심박수 $bpm회, $headline',
            child: ExcludeSemantics(
              // 68pt 숫자와 단위를 한 줄에 둔다. 좁은 화면이나 큰 글자에서는
              // 줄을 통째로 줄여 잘리지 않게 한다.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '$bpm',
                      style: AppText.hero(size: 68, color: AppColors.danger),
                    ),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '회 / 분',
                        style: AppText.label(
                          size: 22,
                          color: AppColors.dangerMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            headline,
            textAlign: TextAlign.center,
            style: AppText.cardTitle(size: 22),
          ),
          const SizedBox(height: 6),
          Text(
            hasUsual ? '$measuredAt · 평소 $usualRange' : measuredAt,
            textAlign: TextAlign.center,
            style: AppText.body(size: 18, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
