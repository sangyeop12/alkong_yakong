import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_bottom_nav.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_feedback.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../guardian/application/guardians_provider.dart';
import '../../../guardian/data/alert_repository.dart';
import '../../../guardian/presentation/screens/care_family_screen.dart';
import '../../../guardian/presentation/screens/care_patient_screen.dart';
import '../../../guardian/presentation/screens/guardian_info_screen.dart';
import '../../../guardian/presentation/screens/guardian_prescription_screen.dart';
import '../../application/medication_history_provider.dart';
import '../../../medication/application/medication_controller.dart';
import '../../../medication/domain/medication_models.dart';
import 'medication_record_screen.dart';
import 'month_calendar_screen.dart';
import 'patient_data.dart';

/// 보호자 쉘 — 탭은 프로토타입대로 **돌보는 분 · 정보** 둘이다.
///
/// 알림은 목록 헤더의 종 단추로, 어르신 현황은 목록에서 눌러 들어간다.
/// 보호자 전용 남색 액센트는 폐기했다. 환자와 같은 파란 규칙을 쓰고,
/// 역할 구분은 탭 라벨과 상단 "보호자 화면" 라벨로만 한다.
class GuardianHomeScreen extends ConsumerStatefulWidget {
  /// 화면 확인용 임시 통로에서 가짜 알림을 넣을 때만 쓴다.
  final AlertRepository? alertsRepository;

  const GuardianHomeScreen({super.key, this.alertsRepository});

  @override
  ConsumerState<GuardianHomeScreen> createState() => _GuardianHomeScreenState();
}

class _GuardianHomeScreenState extends ConsumerState<GuardianHomeScreen> {
  int _index = 0;

  static const List<SeniorNavItem> _tabs = [
    SeniorNavItem(icon: TablerIcons.users, label: '돌보는 분'),
    SeniorNavItem(icon: TablerIcons.user, label: '정보'),
  ];

  /// 어르신을 고르면 현황 화면을 연다. 탭을 바꾸지 않는다.
  void _openPatient(CarePatient patient) {
    final patients =
        ref.read(careOverviewProvider).valueOrNull?.patients ??
        const <CarePatient>[];
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GuardianStatusScreen(
          patient: patient,
          position: patients.indexOf(patient) + 1,
          total: patients.length,
          alertsRepository: widget.alertsRepository,
        ),
      ),
    );
  }

  void _openAlerts() {
    final patients =
        ref.read(careOverviewProvider).valueOrNull?.patients ??
        const <CarePatient>[];
    if (patients.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GuardianAlertsScreen(
          patient: patients.first,
          repository: widget.alertsRepository,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: IndexedStack(
        index: _index,
        children: [
          CareFamilyScreen(
            onOpenPatient: _openPatient,
            onOpenAlerts: _openAlerts,
          ),
          const GuardianInfoScreen(),
        ],
      ),
      bottomNavigationBar: SeniorBottomNav(
        items: _tabs,
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
      ),
    );
  }
}

/// 어르신 번호로 전화 앱을 연다. 번호가 없거나 못 열면 그렇다고 말한다.
Future<void> _callPatient(BuildContext context, CarePatient patient) async {
  final digits = (patient.phone ?? '').replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) {
    showSeniorSnackbar(
      context,
      '${patient.name} 님 전화번호가 등록돼 있지 않아요',
      error: true,
    );
    return;
  }
  var opened = false;
  try {
    opened = await launchUrl(Uri(scheme: 'tel', path: digits));
  } catch (_) {
    opened = false;
  }
  if (!opened && context.mounted) {
    showSeniorSnackbar(context, '전화 앱을 열지 못했어요', error: true);
  }
}

// ════════════════════════════════════════════════════════════════
//  보호자 · 어르신 현황 (프로토타입 88)
// ════════════════════════════════════════════════════════════════

/// 보호자가 할 수 있는 일: 조회 · 전화 · 대신 등록.
/// **대신 복약 체크는 할 수 없다** — 오기록을 막기 위해서다.
class GuardianStatusScreen extends ConsumerWidget {
  final CarePatient patient;

  /// 목록에서 몇 번째 분인지. "3명 중 1번째"로 읽힌다.
  final int position;
  final int total;

  final AlertRepository? alertsRepository;

  const GuardianStatusScreen({
    super.key,
    required this.patient,
    required this.position,
    required this.total,
    this.alertsRepository,
  });

  /// 그 시간대를 드신 시각 — "8시 10분". 기록이 없으면 null.
  ///
  /// 값은 서버가 슬롯마다 실어 보낸 것만 쓴다. "오늘 있었던 일" 글귀를
  /// 문자열로 뒤져 찾으면 그 글귀가 한 글자만 바뀌어도 시각이 조용히 사라진다.
  static String? _takenAt(CareSlot slot) {
    if (!slot.taken) return null;
    final parts = slot.time.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    return minute == 0 ? '$hour시' : '$hour시 $minute분';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slots = patient.slots;
    final heartRate = patient.heartRate;
    // 복약 달력은 어르신 화면과 같은 것을 쓴다. 보호자가 보는 그림과
    // 어르신이 보는 그림이 다르면 통화로 맞춰 볼 수가 없다.
    final today =
        ref.watch(patientTodayProvider(patient.patientId)).valueOrNull ??
        TodayMedication.empty;
    final history =
        ref.watch(patientHistoryProvider(patient.patientId)).valueOrNull ??
        const <DateTime, DayAdherence>{};

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          SeniorHeader(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SeniorBackButton(onTap: () => Navigator.of(context).pop()),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    patient.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.screenTitle(size: 26),
                  ),
                ),
              ],
            ),
          ),
          // ── 6. 당겨서 새로고침을 두지 않는다 ──
          // 내용이 화면에 들어오는데도 늘 끌리게 만들어야 해서, 스크롤할
          // 것이 없는데 화면이 몇 px씩 들썩였다.
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (patient.needsAttention) ...[
                    _AttentionCard(
                      text: '${patient.nextDoseLabel} 약을 드시지 않았어요',
                      onCall: () => _callPatient(context, patient),
                    ),
                    const SizedBox(height: 14),
                  ],
                  SeniorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 6,
                    ),
                    child: Column(
                      children: [
                        for (int i = 0; i < slots.length; i++) ...[
                          if (i > 0) const SeniorDivider(),
                          _StatusRow(
                            icon: slots[i].taken
                                ? TablerIcons.circle_check_filled
                                : TablerIcons.circle,
                            iconColor: slots[i].taken
                                ? AppColors.textPrimary
                                : AppColors.danger,
                            label: '${slots[i].label} 약',
                            value:
                                _takenAt(slots[i]) ??
                                (slots[i].taken ? '드셨어요' : '아직'),
                            danger: !slots[i].taken,
                          ),
                        ],
                        if (heartRate != null) ...[
                          if (slots.isNotEmpty) const SeniorDivider(),
                          _StatusRow(
                            icon: TablerIcons.heart_filled,
                            iconColor: AppColors.point,
                            label: '심박수',
                            value:
                                '$heartRate'
                                '${patient.heartRateNormal == false ? ' 빠름' : ' 정상'}',
                            danger: patient.heartRateNormal == false,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (slots.isEmpty && heartRate == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(
                        '오늘 온 기록이 아직 없어요.',
                        style: AppText.body(size: 18),
                      ),
                    ),
                  const SizedBox(height: 12),
                  // 처음엔 이번 주만. "달력으로 보기"를 누르면 한 달로 넓힌다.
                  AdherenceWeekCard(
                    days: weekAdherenceStatuses(today, history),
                    onOpenCalendar: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => MonthCalendarScreen(
                          patientUserId: patient.patientId,
                        ),
                      ),
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
              child: SeniorButton(
                label: '처방전 대신 찍기',
                icon: TablerIcons.camera,
                minHeight: 70,
                onPressed: () => openGuardianPrescription(context, patient),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 빨간 줄이 선 흰 카드. 프로토타입 88의 "확인이 필요해요".
class _AttentionCard extends StatelessWidget {
  final String text;
  final VoidCallback onCall;

  const _AttentionCard({required this.text, required this.onCall});

  @override
  Widget build(BuildContext context) {
    return AccentCard(
      accent: AppColors.danger,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '확인이 필요해요',
            style: AppText.cardTitle(size: 18, color: AppColors.danger),
          ),
          const SizedBox(height: 6),
          Text(text, style: AppText.emphasis(size: 23)),
          const SizedBox(height: 14),
          SeniorButton(
            label: '전화 드리기',
            icon: TablerIcons.phone,
            kind: SeniorButtonKind.neutral,
            minHeight: 62,
            fontSize: 21,
            onPressed: onCall,
          ),
        ],
      ),
    );
  }
}

/// 아침 약 · 8시 10분처럼 한 줄.
class _StatusRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final bool danger;

  const _StatusRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          ExcludeSemantics(child: Icon(icon, size: 28, color: iconColor)),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: AppText.cardTitle(
                size: 21,
                color: danger ? AppColors.danger : AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: AppText.cardTitle(
                size: 20,
                color: danger ? AppColors.danger : AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
//  4k — 알림
// ════════════════════════════════════════════════════════════════

/// "확인했어요"는 알림을 읽음 처리할 뿐 **삭제하지 않는다**.
/// 어르신 쪽 재알림 사다리도 계속 진행된다.
class GuardianAlertsTab extends StatefulWidget {
  final CarePatient patient;

  /// 알림을 읽어 올 곳. 없으면 이 탭이 하나 만들어 쓴다.
  final AlertRepository? repository;

  const GuardianAlertsTab({super.key, required this.patient, this.repository});

  @override
  State<GuardianAlertsTab> createState() => _GuardianAlertsTabState();
}

class _GuardianAlertsTabState extends State<GuardianAlertsTab> {
  final Set<int> _acknowledged = <int>{};

  late final AlertRepository _repository =
      widget.repository ?? AlertRepository();

  List<AlertItem>? _loaded;
  bool _failed = false;

  /// 별일이 없다는 말은 알림으로 띄우지 않는다.
  ///
  /// "일주일 동안 모두 정상이었어요" 같은 줄이 쌓이면, 정작 손이 가야 할
  /// 알림이 그 사이에 묻힌다. 알림은 할 일이 있을 때만 온다.
  static bool _worthTelling(AlertItem alert) {
    const actionable = {'miss', 'alert', 'refill', 'prescription', 'done'};
    if (!actionable.contains(alert.type)) return false;
    if (alert.type == 'alert' && alert.desc.contains('정상')) return false;
    return true;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    final loaded = await _repository.fetch(widget.patient.patientId);
    if (!mounted) return;
    // 못 읽으면 못 읽었다고 말한다. 예시 알림으로 갈아끼우지 않는다.
    setState(() {
      _loaded = loaded?.where(_worthTelling).toList();
      _failed = loaded == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final alerts = _loaded;
    return Column(
      children: [
        Expanded(
          child: alerts == null
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SeniorCard(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 14,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              _failed ? '알림을 불러오지 못했어요' : '불러오는 중이에요',
                              style: AppText.body(size: 18),
                            ),
                            if (_failed) ...[
                              const SizedBox(height: 12),
                              SeniorButton(
                                label: '다시 불러오기',
                                kind: SeniorButtonKind.secondary,
                                minHeight: 58,
                                fontSize: 20,
                                onPressed: _load,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                    itemCount: alerts.isEmpty ? 1 : alerts.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      if (alerts.isEmpty) {
                        return Text(
                          '아직 온 알림이 없어요.',
                          textAlign: TextAlign.center,
                          style: AppText.caption(size: 17),
                        );
                      }
                      return _AlertCard(
                        alert: alerts[index],
                        patient: widget.patient,
                        acknowledged: _acknowledged.contains(index),
                        onAcknowledge: () =>
                            setState(() => _acknowledged.add(index)),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

/// 목록 헤더의 종 단추로 들어오는 알림 화면 (프로토타입 89).
class GuardianAlertsScreen extends StatelessWidget {
  final CarePatient patient;
  final AlertRepository? repository;

  const GuardianAlertsScreen({
    super.key,
    required this.patient,
    this.repository,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const SeniorBackHeader(title: '알림', alignStart: true),
          Expanded(
            child: GuardianAlertsTab(patient: patient, repository: repository),
          ),
        ],
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  final AlertItem alert;
  final CarePatient patient;
  final bool acknowledged;
  final VoidCallback onAcknowledge;

  const _AlertCard({
    required this.alert,
    required this.patient,
    required this.acknowledged,
    required this.onAcknowledge,
  });

  bool get _isDanger =>
      alert.type == 'miss' || alert.type == 'alert' || alert.type == 'refill';

  Color get _barColor {
    if (_isDanger) return AppColors.danger;
    // 지난 것은 회색으로 뒤로 물린다. 지우지는 않는다.
    if (alert.type == 'past') return AppColors.surface;
    return AppColors.point;
  }

  @override
  Widget build(BuildContext context) {
    // 색 카드가 한 장 뒤에 깔린 모양. 지난 것은 뒤 카드도 흰색이라
    // 겹친 자리가 보이지 않는다 — 지우지는 않고 뒤로 물린다.
    return AccentCard(
      accent: _barColor,
      // 링크가 붙는 카드는 아래를 더 좁힌다. SeniorTextButton 이 터치
      // 영역 48px을 위해 제 아래에 12를 갖고 있어, 카드 여백과 겹쳐
      // 글자 밑이 유독 벌어진다. 터치 영역은 그대로 두고 카드만 줄인다.
      padding: EdgeInsets.fromLTRB(
        22,
        16,
        22,
        alert.type == 'prescription' ? 4 : 16,
      ),
      child: _content(context),
    );
  }

  /// 누구 알림인지 — "어머니(김복자)". 호칭을 모르면 이름만.
  String get _who => patient.relation.isEmpty
      ? patient.name
      : '${patient.relation}(${patient.name})';

  /// 무슨 일인지. 서버 글귀가 "어머니가 …"로 시작하면 그 앞부분을 덜어낸다
  /// — 누구인지는 윗줄이 이미 말한다.
  String get _what {
    var text = alert.desc.trim();
    for (final name in [patient.relation, patient.name, _who]) {
      if (name.isEmpty) continue;
      for (final josa in ['가 ', '이 ', '은 ', '는 ', '님이 ', '님은 ']) {
        final head = '$name$josa';
        if (text.startsWith(head)) return text.substring(head.length).trim();
      }
    }
    return text;
  }

  Widget _content(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _who,
                style: AppText.cardTitle(
                  size: 18,
                  color: _barColor,
                  weight: FontWeight.w900,
                ),
                // 첫 줄 위에 남는 행간을 끈다. 마지막 줄 아래도 껐으므로
                // 글자와 카드 사이가 위아래 같은 폭으로 떨어진다.
                textHeightBehavior: const TextHeightBehavior(
                  applyHeightToFirstAscent: false,
                ),
              ),
            ),
            Text(
              alert.time,
              style: AppText.label(size: 17, color: AppColors.textTertiary),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _what,
          style: AppText.label(size: 20.5, color: AppColors.textPrimary),
          // 행간(1.5)의 아래쪽 몫이 마지막 줄 밑에 남아, 같은 여백인데도
          // 아래가 더 벌어져 보인다. 마지막 줄의 아래 행간만 끈다.
          textHeightBehavior: const TextHeightBehavior(
            applyHeightToLastDescent: false,
          ),
        ),
        if (alert.type == 'prescription') ...[
          Align(
            alignment: Alignment.centerLeft,
            // 새로 들어온 약은 현황이 아니라 명단에서 손본다.
            child: SeniorTextButton(
              label: '돌보는 분 관리에서 보기',
              expand: false,
              fontSize: 19,
              color: AppColors.point,
              // 목록을 한 번 더 거치지 않고 그 어르신 화면으로 바로 간다.
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CarePatientScreen(patient: patient),
                ),
              ),
            ),
          ),
        ],
        // 확인한 뒤에는 단추를 남기지 않는다. "확인함"이 눌리지 않는 채로
        // 남아 있으면 아직 할 일이 있는 것처럼 보인다.
        if (_isDanger && !acknowledged) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: SeniorButton(
                  label: '전화 드리기',
                  minHeight: 56,
                  fontSize: 19,
                  onPressed: () => _callPatient(context, patient),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SeniorButton(
                  label: '확인했어요',
                  kind: SeniorButtonKind.secondary,
                  minHeight: 56,
                  fontSize: 19,
                  onPressed: onAcknowledge,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
