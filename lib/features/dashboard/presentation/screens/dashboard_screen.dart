import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_config.dart';
import '../../../../core/session/mvp_session.dart';
import '../../../../core/widgets/rounded_gradient_app_bar.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _apiClient = ApiClient(baseUrl: ApiConfig.localFeatureBaseUrl);

  bool _isLoading = false;
  int? _submittingScheduleId;
  String? _errorMessage;
  Map<String, dynamic>? _dashboard;
  final Set<String> _locallyTakenScheduleKeys = <String>{};

  // 캘린더를 위한 현재 선택된 날짜
  DateTime _selectedDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshDashboard();
    });
  }

  Future<void> _refreshDashboard() async {
    final userId = MvpSession.userId;
    if (userId.isEmpty) {
      setState(() => _errorMessage = '로그인 정보(사용자 ID)가 없습니다.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final dateStr =
        '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';

    try {
      final response = await _apiClient.get(
        '/api/v1/users/${Uri.encodeComponent(userId)}/dashboard?date=$dateStr',
      );
      if (!mounted) return;
      setState(() {
        _dashboard = Map<String, dynamic>.from(response as Map);
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = _apiError(error));
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = '응답 처리 중 오류가 발생했습니다: $error');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _markTaken(Map<String, dynamic> medication) async {
    final userId = MvpSession.userId;
    final scheduleId = _intValue(medication['schedule_id'] ?? medication['id']);
    if (userId.isEmpty || scheduleId == null) {
      setState(() => _errorMessage = '사용자 또는 복약 일정 정보가 없습니다.');
      return;
    }

    setState(() {
      _submittingScheduleId = scheduleId;
      _errorMessage = null;
    });
    try {
      await _apiClient.post(
        '/api/v1/medication-logs',
        body: {'user_id': userId, 'schedule_id': scheduleId},
      );
      await _refreshDashboard();
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = _apiError(error));
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = '복약 완료 처리 중 오류가 발생했습니다: $error');
    } finally {
      if (mounted) setState(() => _submittingScheduleId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 처음 불러오는 동안에는 빈 화면 대신 그렇다고 말한다.
    if (_isLoading && _dashboard == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final medication = _asMap(_dashboard?['medication_summary']);
    final todayMedications = _dashboard?['today_medications'];
    final summarySchedules = medication?['schedules'];
    final rawSchedules = todayMedications is List
        ? todayMedications
        : summarySchedules is List
        ? summarySchedules
        : const <dynamic>[];
    final filteredSchedules = rawSchedules.where((schedule) {
      final item = _asMap(schedule);
      return item == null || !_isAspirinFallbackItem(item);
    }).toList();
    final sessionSchedules = _latestOcrSchedulesForDate(_selectedDate);
    final schedules = filteredSchedules.isNotEmpty
        ? filteredSchedules
        : sessionSchedules;
    final risk = _asMap(_dashboard?['latest_risk']);
    final prescription = _asMap(_dashboard?['latest_prescription']);
    final event = _asMap(_dashboard?['latest_abnormal_event']);
    final prescriptionMedicines = _stringList(prescription?['medicine_names']);
    final visiblePrescriptionMedicines = prescriptionMedicines
        .where((name) => !_isAspirinFallbackText(name))
        .toList();
    final visiblePrescription =
        visiblePrescriptionMedicines.isEmpty && sessionSchedules.isEmpty
        ? null
        : prescription;
    final displayedPrescriptionMedicines =
        visiblePrescriptionMedicines.isNotEmpty
        ? visiblePrescriptionMedicines
        : sessionSchedules
              .map((item) => _text(item['drug_name'], fallback: ''))
              .where((name) => name.isNotEmpty)
              .toList();
    final hasDisplayedPrescription = displayedPrescriptionMedicines.isNotEmpty;
    final displayedPrescriptionTitle = visiblePrescription == null
        ? 'OCR 처방전'
        : _text(visiblePrescription['display_name'], fallback: 'OCR 처방전');
    final displayedPrescriptionRegisteredAt = visiblePrescription == null
        ? MvpSession.latestOcrRegisteredAt?.toString() ?? '방금 등록'
        : _text(
            visiblePrescription['registered_at'] ??
                visiblePrescription['created_at'],
            fallback: MvpSession.latestOcrRegisteredAt?.toString() ?? '방금 등록',
          );
    final displayedCompleted = schedules.where((schedule) {
      final item = _asMap(schedule);
      if (item == null) return false;
      return _locallyTakenScheduleKeys.contains(_scheduleKey(item)) ||
          _text(item['status'], fallback: 'PENDING').toUpperCase() == 'TAKEN';
    }).length;

    return Scaffold(
      backgroundColor: kBackground,
      appBar: const RoundedGradientAppBar('복약 기록'),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refreshDashboard,
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 20),
            children: [
              // 주간 캘린더 UI
              _WeeklyCalendar(
                selectedDate: _selectedDate,
                onDateSelected: (date) {
                  setState(() => _selectedDate = date);
                  _refreshDashboard();
                },
              ),
              const SizedBox(height: 16),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_errorMessage != null) ...[
                      _DashboardCard(
                        title: '조회 실패',
                        value: _errorMessage!,
                        icon: Icons.error_outline,
                        color: Colors.red,
                      ),
                      const SizedBox(height: 16),
                    ],

                    Text(
                      '${_selectedDate.month}월 ${_selectedDate.day}일 요약',
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: kText,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _DashboardCard(
                      title: '이날의 복약',
                      value:
                          '$displayedCompleted / '
                          '${schedules.length} 완료',
                      icon: Icons.medication_outlined,
                      color: kPrimary,
                    ),
                    const SizedBox(height: 10),
                    if (schedules.isEmpty)
                      const _SmallDataCard(title: '복약 일정', value: '데이터 없음')
                    else
                      ...schedules.map((schedule) {
                        final item =
                            _asMap(schedule) ?? const <String, dynamic>{};
                        final scheduleId = _intValue(
                          item['schedule_id'] ?? item['id'],
                        );
                        final scheduleKey = _scheduleKey(item);
                        final effectiveStatus =
                            _locallyTakenScheduleKeys.contains(scheduleKey)
                            ? 'TAKEN'
                            : _text(item['status'], fallback: 'PENDING');
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _MedicationCard(
                            time: _text(item['time'] ?? item['scheduled_time']),
                            drugName: _text(
                              item['drug_name'] ?? item['product_name'],
                            ),
                            ingredient: _text(item['ingredient']),
                            status: effectiveStatus,
                            isSubmitting:
                                scheduleId != null &&
                                _submittingScheduleId == scheduleId,
                            onTaken: scheduleId == null
                                ? () {
                                    setState(() {
                                      _locallyTakenScheduleKeys.add(
                                        scheduleKey,
                                      );
                                    });
                                  }
                                : () => _markTaken(item),
                          ),
                        );
                      }),
                    const SizedBox(height: 4),
                    _DashboardCard(
                      title: 'DUR 위험도',
                      value: risk == null
                          ? '데이터 없음'
                          : '${_text(risk['risk_level'])} · '
                                '${_text(risk['total_matches'], fallback: '0')}건\n'
                                '대표 유형: ${_text(risk['representative_type'])}',
                      icon: Icons.health_and_safety_outlined,
                      color: _riskColor(
                        _text(risk?['risk_level'], fallback: 'LOW'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _DashboardCard(
                      title: '최근 처방전',
                      value: !hasDisplayedPrescription
                          ? '데이터 없음'
                          : '$displayedPrescriptionTitle\n'
                                '등록일: $displayedPrescriptionRegisteredAt\n'
                                '약: ${displayedPrescriptionMedicines.take(3).join(', ')}',
                      icon: Icons.description_outlined,
                      color: AppColors.legacyBlue,
                    ),
                    const SizedBox(height: 10),
                    _DashboardCard(
                      title: '최근 생체신호 이벤트',
                      value: event == null
                          ? '데이터 없음'
                          : '${_text(event['event_type'])} · ${_text(event['bpm'])} BPM\n'
                                '${_text(event['occurred_at'])}',
                      icon: Icons.monitor_heart_outlined,
                      color: Colors.redAccent,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// 주간 캘린더 위젯
class _WeeklyCalendar extends StatelessWidget {
  final DateTime selectedDate;
  final Function(DateTime) onDateSelected;

  const _WeeklyCalendar({
    required this.selectedDate,
    required this.onDateSelected,
  });

  @override
  Widget build(BuildContext context) {
    // 오늘 기준으로 앞뒤 3일씩 (총 7일)을 생성하여 보여줍니다.
    final today = DateTime.now();
    final List<DateTime> weekDays = List.generate(
      7,
      (index) => today.subtract(Duration(days: 3 - index)),
    );

    return SizedBox(
      height: 90,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: weekDays.length,
        itemBuilder: (context, index) {
          final date = weekDays[index];
          final isSelected =
              date.year == selectedDate.year &&
              date.month == selectedDate.month &&
              date.day == selectedDate.day;

          final dayName = const [
            '월',
            '화',
            '수',
            '목',
            '금',
            '토',
            '일',
          ][date.weekday - 1];

          return GestureDetector(
            onTap: () => onDateSelected(date),
            child: Container(
              width: 60,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: isSelected ? kPrimary : Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isSelected ? kPrimary : Colors.grey[300]!,
                ),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: kPrimary.withValues(alpha: 0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : null,
              ),
              // 칸 높이가 정해져 있어 글자를 키우면 아래로 넘친다.
              // 칸 안에서 요일·날짜를 함께 줄인다.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      dayName,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isSelected ? Colors.white : Colors.grey[500],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${date.day}',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: isSelected ? Colors.white : kText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DashboardCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _DashboardCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: kText,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  value,
                  style: const TextStyle(color: kTextSub, height: 1.45),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SmallDataCard extends StatelessWidget {
  final String title;
  final String value;

  const _SmallDataCard({required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: kPrimaryLight,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: const TextStyle(color: kText)),
          ),
          Text(value, style: const TextStyle(fontSize: 12, color: kTextSub)),
        ],
      ),
    );
  }
}

class _MedicationCard extends StatelessWidget {
  final String time;
  final String drugName;
  final String ingredient;
  final String status;
  final bool isSubmitting;
  final VoidCallback onTaken;

  const _MedicationCard({
    required this.time,
    required this.drugName,
    required this.ingredient,
    required this.status,
    required this.isSubmitting,
    required this.onTaken,
  });

  @override
  Widget build(BuildContext context) {
    final normalizedStatus = status.toUpperCase();
    final isTaken = normalizedStatus == 'TAKEN';
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: kPrimaryLight,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$time · $drugName',
                  style: const TextStyle(
                    color: kText,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _MedicationStatus(status: normalizedStatus),
            ],
          ),
          const SizedBox(height: 7),
          Text(ingredient, style: const TextStyle(color: kTextSub)),
          if (!isTaken) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: isSubmitting ? null : onTaken,
                child: Text(isSubmitting ? '처리 중...' : '약 먹었어요'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MedicationStatus extends StatelessWidget {
  final String status;

  const _MedicationStatus({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'TAKEN' => kPrimary,
      'MISSED' => Colors.red,
      _ => Colors.orange,
    };
    final label = switch (status) {
      'TAKEN' => '복약 완료',
      'MISSED' => '복약 놓침',
      _ => '복약 전',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

Map<String, dynamic>? _asMap(dynamic value) {
  return value is Map ? Map<String, dynamic>.from(value) : null;
}

List<String> _stringList(dynamic value) {
  if (value is! List) return const [];
  return value
      .map((item) => item?.toString().trim() ?? '')
      .where((item) => item.isNotEmpty)
      .toList();
}

List<Map<String, dynamic>> _latestOcrSchedulesForDate(DateTime selectedDate) {
  final registeredAt = MvpSession.latestOcrRegisteredAt;
  final items = MvpSession.latestOcrItems;
  if (registeredAt == null || items.isEmpty) return const [];
  if (registeredAt.year != selectedDate.year ||
      registeredAt.month != selectedDate.month ||
      registeredAt.day != selectedDate.day) {
    return const [];
  }

  final schedules = <Map<String, dynamic>>[];
  for (final item in items) {
    final frequency = _intValue(item['frequency_per_day']) ?? 1;
    final times = switch (frequency.clamp(1, 3)) {
      1 => ['08:00'],
      2 => ['08:00', '20:00'],
      _ => ['08:00', '13:00', '20:00'],
    };
    for (final time in times) {
      schedules.add({
        'time': time,
        'scheduled_time': time,
        'drug_name': item['drug_name'],
        'product_name': item['drug_name'],
        'ingredient': item['easy_explanation'] ?? '',
        'status': 'PENDING',
      });
    }
  }
  return schedules;
}

String _text(dynamic value, {String fallback = '데이터 없음'}) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? fallback : text;
}

int? _intValue(dynamic value) {
  return value is int ? value : int.tryParse(value?.toString() ?? '');
}

String _scheduleKey(Map<String, dynamic> item) {
  final id = _intValue(item['schedule_id'] ?? item['id']);
  if (id != null) return 'id:$id';

  final time = _text(item['time'] ?? item['scheduled_time'], fallback: '');
  final drugName = _text(
    item['drug_name'] ?? item['product_name'],
    fallback: '',
  );
  final ingredient = _text(item['ingredient'], fallback: '');
  return 'local:$time|$drugName|$ingredient';
}

bool _isAspirinFallbackItem(Map<String, dynamic> item) {
  return _isAspirinFallbackText(item['drug_name']) ||
      _isAspirinFallbackText(item['product_name']) ||
      _isAspirinFallbackText(item['ingredient']) ||
      _isAspirinFallbackText(item['medicine_name']);
}

bool _isAspirinFallbackText(dynamic value) {
  final compact = value?.toString().replaceAll(' ', '').toLowerCase() ?? '';
  return compact.contains('아스피린') || compact.contains('aspirin');
}

String _apiError(ApiException error) {
  return error.statusCode == null
      ? error.message
      : '${error.message} (HTTP ${error.statusCode})';
}

Color _riskColor(String riskLevel) {
  return switch (riskLevel.toUpperCase()) {
    'CRITICAL' || 'HIGH' => Colors.red,
    'WARNING' || 'CAUTION' => Colors.orange,
    _ => kPrimary,
  };
}
