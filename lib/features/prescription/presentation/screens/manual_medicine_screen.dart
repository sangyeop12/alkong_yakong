import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_config.dart';
import '../../../../core/session/mvp_session.dart';
import '../../domain/registration_result.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_feedback.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../dashboard/application/medication_history_provider.dart';
import '../../../medication/application/medication_controller.dart';
import '../../../medicines/application/user_medicines_controller.dart';

/// 처방전 없이 공식 약 이름을 찾아 등록한다.
class ManualMedicineScreen extends ConsumerStatefulWidget {
  final VoidCallback? onBack;
  final ValueChanged<Map<String, dynamic>?>? onSaved;

  const ManualMedicineScreen({super.key, this.onBack, this.onSaved});

  @override
  ConsumerState<ManualMedicineScreen> createState() =>
      _ManualMedicineScreenState();
}

class _ManualMedicineScreenState extends ConsumerState<ManualMedicineScreen> {
  final _api = ApiClient(baseUrl: ApiConfig.localFeatureBaseUrl);
  final _query = TextEditingController();
  final _amount = TextEditingController();

  List<Map<String, dynamic>> _hits = const [];
  Map<String, dynamic>? _picked;
  int? _frequency;
  int? _days;

  /// 드시는 때. 이게 없으면 알림 시각을 정할 수 없다.
  final Set<String> _slots = <String>{};
  bool _searching = false;
  bool _saving = false;

  /// 글자를 멈추면 알아서 찾는다. 버튼을 하나 더 누르게 하지 않는다.
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _amount.dispose();
    super.dispose();
  }

  /// 오류는 버튼 아래에 끼워 넣지 않고 스낵바로 알린다.
  void _showError(String message) =>
      showSeniorSnackbar(context, message, error: true);

  void _searchLater() {
    _debounce?.cancel();
    if (_query.text.trim().length < 2) {
      setState(() => _hits = const []);
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 500),
      () => _search(quiet: true),
    );
  }

  Future<void> _search({bool quiet = false}) async {
    _debounce?.cancel();
    final q = _query.text.trim();
    if (q.length < 2) {
      if (!quiet) _showError('약 이름을 두 글자 이상 적어 주세요.');
      return;
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    setState(() {
      _searching = true;
      _picked = null;
    });
    try {
      final response = await _api.get(
        '/api/v1/medicines/lookup?q=${Uri.encodeQueryComponent(q)}',
      );
      if (!mounted) return;
      final items = response is Map ? response['items'] : null;
      final hits = items is List
          ? items
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .toList()
          : <Map<String, dynamic>>[];
      setState(() {
        _hits = hits;
        _searching = false;
      });
      if (hits.isEmpty && !quiet) {
        _showError('공식 약 이름을 찾지 못했어요. 처방전 사진으로 등록해 주세요.');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _searching = false);
      if (!quiet) _showError('약 이름을 찾지 못했어요. 잠시 후 다시 시도해 주세요.');
    }
  }

  Future<void> _save() async {
    final picked = _picked;
    final code = picked?['medicine_code']?.toString().trim() ?? '';
    if (code.isEmpty) {
      _showError('목록에서 약을 먼저 골라 주세요.');
      return;
    }
    if (_slots.isEmpty) {
      _showError('드시는 때를 한 개 이상 골라 주세요.');
      return;
    }
    // 용량과 날수는 나중에 채워도 된다. 여기서 다 물으면 대부분 포기한다.
    final amount = _amount.text.trim();
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    setState(() => _saving = true);
    final userId = MvpSession.userId.trim().isEmpty
        ? 'mvp-user'
        : MvpSession.userId.trim();
    Map<String, dynamic> mapped;
    try {
      final response = await _api.post(
        '/api/v1/prescriptions/confirm',
        body: {
          'user_id': userId,
          'items': [
            {
              'medicine_code': code,
              'drug_name':
                  picked?['display_name'] ?? picked?['product_name'] ?? '',
              'dosage': amount,
              'frequency_per_day': _frequency ?? _slots.length,
              'times_per_take': 1,
              'duration_days': _days,
              'administration_times': _slots.toList(),
              'match_status': 'MATCHED',
            },
          ],
        },
      );
      if (response is! Map || response['registered'] != true) {
        throw const ApiException('약 등록 완료를 확인하지 못했어요.');
      }
      mapped = Map<String, dynamic>.from(response);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      _showError('공식 약으로 확인되지 않아 등록하지 못했어요.');
      return;
    }

    MvpSession.rememberPrescriptionSchedules(
      prescriptionId: mapped['prescription_id']?.toString(),
      confirmResponse: mapped,
      ocrItems: [
        {
          'duration_days': _days,
          'frequency_per_day': _frequency ?? _slots.length,
        },
      ],
    );
    // 함께먹기 검사가 끝나지 않았으면 "안전"으로 읽지 않는다.
    final durResult = registrationDurResult(mapped['dur_result']);
    var refreshFailed = false;
    try {
      await Future.wait<void>([
        ref
            .read(medicationProvider.notifier)
            .refreshFromServer(throwOnError: true),
        ref.read(userMedicinesProvider.notifier).refresh(),
      ]);
    } catch (_) {
      refreshFailed = true;
    }
    ref.invalidate(medicationHistoryProvider);
    if (ref.read(userMedicinesProvider).hasError) {
      refreshFailed = true;
    }
    if (!mounted) return;
    if (refreshFailed) {
      showSeniorSnackbar(context, '약은 등록됐지만 목록을 다시 불러와야 해요.');
    }
    final onSaved = widget.onSaved;
    if (onSaved != null) {
      onSaved(durResult);
      return;
    }
    // 부딪히는 약이 있으면 그것부터 보여주고, 아니면 약 있는 날로 간다.
    if (_hasPairConflict(durResult)) {
      context.push(
        '/dur-analysis',
        extra: {...durResult, 'open_schedule_days': true},
      );
      return;
    }
    context.push('/schedule-days', extra: MvpSession.latestPrescriptionId);
  }

  static bool _hasPairConflict(Map<String, dynamic>? durResult) {
    const pairTypes = {'병용금기', '중복성분', '효능군중복'};
    final matches = durResult?['matches'];
    if (matches is! List) return false;
    return matches.any(
      (item) => item is Map && pairTypes.contains(item['type']?.toString()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          SeniorBackHeader(
            title: '손으로 적기',
            onBack: widget.onBack ?? () => context.pop(),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 18,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.pointTint,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '약 이름과 드시는 때만 적으면 돼요',
                        style: AppText.cardTitle(
                          size: 20,
                          color: AppColors.point,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '용량과 남은 날수는 나중에 채워도 됩니다.',
                        style: AppText.body(
                          size: 17.5,
                          color: AppColors.pointInk,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SeniorCard(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SeniorField(
                        label: '약 이름',
                        controller: _query,
                        hint: '예: 메트포르민',
                        onChanged: (_) => _searchLater(),
                      ),
                      if (_searching) ...[
                        const SizedBox(height: 12),
                        Text(
                          '약 이름을 찾는 중이에요…',
                          style: AppText.caption(size: 16),
                        ),
                      ],
                      if (_hits.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            for (final hit in _hits)
                              _NameChip(
                                label:
                                    hit['display_name']?.toString() ??
                                    hit['product_name']?.toString() ??
                                    '약',
                                selected:
                                    _picked?['medicine_code'] ==
                                    hit['medicine_code'],
                                onTap: () => setState(() => _picked = hit),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SeniorCard(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SeniorField(
                        label: '한 번에 먹는 양',
                        controller: _amount,
                        hint: '예: 1알 또는 0.5정',
                      ),
                      const SizedBox(height: 18),
                      Text('하루 복용 횟수', style: AppText.label(size: 18)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          for (
                            int i = 0;
                            i < _frequencyOptions.length;
                            i++
                          ) ...[
                            if (i > 0) const SizedBox(width: 10),
                            Expanded(
                              child: _OptionChip(
                                label: '${_frequencyOptions[i]}번',
                                selected: _frequency == _frequencyOptions[i],
                                onTap: () => setState(
                                  () => _frequency = _frequencyOptions[i],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 18),
                      Text('며칠분', style: AppText.label(size: 18)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          for (int i = 0; i < _dayOptions.length; i++) ...[
                            if (i > 0) const SizedBox(width: 10),
                            Expanded(
                              child: _OptionChip(
                                label: '${_dayOptions[i]}일',
                                selected: _days == _dayOptions[i],
                                onTap: () =>
                                    setState(() => _days = _dayOptions[i]),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SeniorCard(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text('드시는 때', style: AppText.cardTitle(size: 20)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '(여러 개 고를 수 있어요)',
                              style: AppText.caption(size: 16),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (int i = 0; i < _slotLabels.length; i++) ...[
                              if (i > 0) const SizedBox(width: 10),
                              Expanded(
                                child: _SlotChip(
                                  label: _slotLabels[i],
                                  selected: _slots.contains(_slotLabels[i]),
                                  onTap: () => setState(() {
                                    if (!_slots.remove(_slotLabels[i])) {
                                      _slots.add(_slotLabels[i]);
                                    }
                                  }),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                SeniorButton(
                  label: _saving ? '등록 중…' : '이 약 등록하기',
                  onPressed: _saving ? () {} : _save,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 드시는 때 후보. 한 번에 여러 개를 고를 수 있다.
const List<String> _slotLabels = ['아침', '점심', '저녁'];

/// 하루 몇 번, 며칠분. 목록을 펼치게 하지 않고 눌러서 고른다.
const List<int> _frequencyOptions = [1, 2, 3];
const List<int> _dayOptions = [3, 7, 14, 30];

/// 찾은 약 이름 한 알. 고르면 파란 테두리가 생긴다.
class _NameChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NameChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? AppColors.pointTint : AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? AppColors.point : AppColors.strongLine,
              width: 2,
            ),
          ),
          child: Text(
            label,
            style: AppText.label(
              size: 18,
              color: selected ? AppColors.point : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 숫자 하나를 고르는 칸. 고른 것만 파란 글씨·테두리다.
class _OptionChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _OptionChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 62),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? AppColors.pointTint : AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? AppColors.point : AppColors.strongLine,
              width: 2,
            ),
          ),
          child: Text(
            label,
            style: AppText.cardTitle(
              size: 19,
              color: selected ? AppColors.point : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 3분할 칩. 고르면 파랑으로 채워진다.
class _SlotChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SlotChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '$label ${selected ? '고름' : '고르지 않음'}',
      child: GestureDetector(
        onTap: onTap,
        child: ExcludeSemantics(
          child: Container(
            constraints: const BoxConstraints(minHeight: 70),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
            decoration: BoxDecoration(
              color: selected ? AppColors.point : AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected
                    ? AppColors.pointBorder
                    : AppColors.strongBorder,
                width: 2,
              ),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: AppText.cardTitle(
                size: 19,
                color: selected ? Colors.white : AppColors.textBody,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
