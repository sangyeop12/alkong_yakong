import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_config.dart';
import '../../../../core/session/mvp_session.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/recovery_view.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_feedback.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../../core/widgets/senior_sheet.dart';
import '../../../../core/widgets/senior_timeline.dart';
import '../../../dashboard/application/medication_history_provider.dart';
import '../../../medication/application/medication_controller.dart';
import '../../../medicines/application/user_medicines_controller.dart';
import '../../../medicines/domain/display_policy.dart';
import '../../../onboarding/presentation/screens/first_run_screen.dart';
import 'add_medicine_screen.dart';
import 'manual_medicine_screen.dart';
import '../widgets/fix_name_sheet.dart';

/// 처방전 등록 흐름의 단계.
enum PrescriptionStep {
  /// 07 — 어떻게 넣을지 고르기.
  pickMethod,

  /// 4d — 처방전 촬영.
  capture,

  /// 10 — 손으로 적기.
  manual,

  /// 읽는 중.
  reading,

  /// 4e — 이렇게 읽었어요.
  confirm,

  /// 읽지 못했을 때 (5e 회복 패턴).
  failed,
}

/// 4d · 4e — 처방전 찍기 / 이렇게 읽었어요.
///
/// "처방전 OCR 인식"이라는 말을 쓰지 않는다.
/// 읽지 못했을 때도 사용자를 탓하지 않는다 — "다시 찍어드릴게요".
class PrescriptionScreen extends ConsumerStatefulWidget {
  /// 함께 보는 가족 — "딸 지안 님".
  final String guardianTitle;

  /// 등록이 끝났을 때 부를 콜백.
  final ValueChanged<Map<String, dynamic>?>? onCompleted;

  /// 가족에게 부탁한 뒤 오늘 화면으로 돌아갈 때.
  final VoidCallback? onGoHome;

  /// 약 있는 날 달력으로 갈 때. 쉬운 모드가 화면을 직접 바꿀 때 쓴다.
  final VoidCallback? onOpenScheduleDays;

  /// 보호자가 대신 넣을 때 그 어르신 호칭 ("어머니 · 김복자").
  /// 값이 있으면 위에 띠가 붙고, 마지막 단추가 "어르신께 보내기"가 된다.
  final String? onBehalfOf;

  /// 대신 넣는 어르신의 id. 약은 이 사람 것으로 들어간다.
  final String? onBehalfOfUserId;

  const PrescriptionScreen({
    super.key,
    this.onCompleted,
    this.onGoHome,
    this.onOpenScheduleDays,
    this.guardianTitle = '',
    this.onBehalfOf,
    this.onBehalfOfUserId,
  });

  @override
  ConsumerState<PrescriptionScreen> createState() => _PrescriptionScreenState();
}

class _PrescriptionScreenState extends ConsumerState<PrescriptionScreen> {
  /// 약을 누구 것으로 넣을지. 대신 넣는 중이면 그 어르신이다.
  String get _targetUserId {
    final onBehalf = widget.onBehalfOfUserId?.trim() ?? '';
    if (onBehalf.isNotEmpty) return onBehalf;
    final mine = MvpSession.userId.trim();
    return mine.isEmpty ? 'mvp-user' : mine;
  }

  final ImagePicker _picker = ImagePicker();
  final ApiClient _localApiClient = ApiClient(
    baseUrl: ApiConfig.localFeatureBaseUrl,
  );

  late PrescriptionStep _step = widget.onBehalfOf == null
      ? PrescriptionStep.pickMethod
      : PrescriptionStep.capture;

  File? _image;
  Map<String, dynamic>? _result;

  /// 촬영 실패 횟수. 3번 실패하면 가족 대행(5g)을 권한다.
  int _failureCount = 0;
  String _failureReason = '';

  List<Map<String, dynamic>> get _items {
    final items = _result?['items'];
    if (items is List && items.isNotEmpty) {
      return items
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .where(_isOfficialMatchedItem)
          .toList();
    }
    return const [];
  }

  List<String> get _unrecognizedNames {
    final raw = _result?['unrecognized_names'];
    if (raw is! List) return const [];
    return raw
        .map((item) => item.toString().trim())
        .where((name) => name.isNotEmpty)
        .toList();
  }

  static bool _isOfficialMatchedItem(Map<String, dynamic> item) {
    final code = item['medicine_code']?.toString() ?? '';
    if (code.isEmpty || code.toUpperCase().startsWith('OCR-')) {
      return false;
    }
    final status = item['match_status']?.toString().toUpperCase() ?? '';
    return status != 'UNMATCHED';
  }

  static bool _hasPairConflict(Map<String, dynamic>? durResult) {
    const pairTypes = {'병용금기', '중복성분', '효능군중복'};
    final matches = durResult?['matches'];
    if (matches is! List) return false;
    return matches.any(
      (item) => item is Map && pairTypes.contains(item['type']?.toString()),
    );
  }

  Future<void> _pick(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(source: source);
      if (picked == null) return;
      setState(() {
        _image = File(picked.path);
        _step = PrescriptionStep.capture;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failureCount++;
        _step = PrescriptionStep.failed;
      });
    }
  }

  Future<void> _read() async {
    setState(() => _step = PrescriptionStep.reading);

    try {
      String? base64Image;
      final image = _image;
      if (image != null) {
        base64Image = base64Encode(await image.readAsBytes());
      }

      // 처방전 사진은 CLOVA OCR 처리 시간을 고려해 여유 있게 기다린다.
      final response = await _localApiClient.post(
        '/api/v1/prescriptions/ocr',
        body: {
          'user_id': _targetUserId,
          'image_data': base64Image,
          'source_type': 'OCR',
        },
        timeout: const Duration(seconds: 90),
      );

      if (!mounted) return;
      final mapped = Map<String, dynamic>.from(response as Map);
      final items = mapped['items'];
      final hasOfficial = items is List && items.isNotEmpty
          ? items
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .where(_isOfficialMatchedItem)
                .isNotEmpty
          : false;
      final unreadRaw = mapped['unrecognized_names'];
      final hasUnread = unreadRaw is List && unreadRaw.isNotEmpty;
      if (!hasOfficial && !hasUnread) {
        setState(() {
          _failureCount++;
          _failureReason = '처방전에서 약을 찾지 못했어요.';
          _step = PrescriptionStep.failed;
        });
        return;
      }

      setState(() {
        _result = mapped;
        _failureCount = 0;
        _step = PrescriptionStep.confirm;
      });

      final first = _items.isEmpty ? null : _items.first;
      if (first != null) {
        MvpSession.medicineCode = first['medicine_code']?.toString() ?? '';
      }
    } catch (error) {
      debugPrint(
        '[PRESCRIPTION_DIAG] OCR failed error_type=${error.runtimeType}',
      );
      if (!mounted) return;
      setState(() {
        _failureCount++;
        _failureReason = error.toString();
        _step = PrescriptionStep.failed;
      });
    }
  }

  Future<void> _register(List<Map<String, dynamic>> editedItems) async {
    final userId = _targetUserId;
    final confirmItems = editedItems
        .where(_isOfficialMatchedItem)
        .map(
          (item) => <String, dynamic>{
            'medicine_code': item['medicine_code'],
            'drug_name': item['drug_name'] ?? item['product_name'] ?? '',
            'ocr_drug_name_raw': item['ocr_drug_name_raw'],
            'ocr_field_confidences': item['ocr_field_confidences'] is Map
                ? item['ocr_field_confidences']
                : <String, dynamic>{},
            'dosage_form': item['dosage_form'],
            'administration_route': item['administration_route'],
            'dosage': item['dosage'],
            'unit': item['unit'],
            'dose_amount': item['dose_amount'],
            'dose_unit': item['dose_unit'],
            'frequency_per_day': item['frequency_per_day'],
            'times_per_take': item['times_per_take'],
            'duration_days': item['duration_days'],
            'administration_times': item['administration_times'] is List
                ? item['administration_times']
                : <String>[],
            'match_status': item['match_status'],
            'easy_explanation': item['easy_explanation'],
            'warning_note': item['warning_note'],
          },
        )
        .toList();

    if (confirmItems.isEmpty) {
      if (!mounted) return;
      showSeniorSnackbar(context, '등록할 약을 찾지 못했어요. 다시 찍어 주세요.', error: true);
      return;
    }

    for (final item in confirmItems) {
      final administrationTimes = item['administration_times'];
      debugPrint(
        '[PRESCRIPTION_DIAG] '
        'duration_days=${item['duration_days'] ?? 'null'} '
        'frequency_per_day=${item['frequency_per_day'] ?? 'null'} '
        'administration_times_count='
        '${administrationTimes is List ? administrationTimes.length : 0}',
      );
    }

    Map<String, dynamic>? durResult;
    try {
      final response = await _localApiClient.post(
        '/api/v1/prescriptions/confirm',
        body: {
          'user_id': userId,
          'items': confirmItems,
          'hospital_name': _result?['hospital_name'],
          'pharmacy_name': _result?['pharmacy_name'],
          'prescribed_date': _result?['prescribed_date'],
          'ocr_text': _result?['ocr_text'],
        },
      );
      if (response is Map) {
        final prescriptionId = response['prescription_id']?.toString().trim();
        debugPrint(
          '[PRESCRIPTION_DIAG] '
          'prescription_id_present=${prescriptionId?.isNotEmpty == true} '
          'schedule_count=${response['schedule_count'] ?? 'unknown'}',
        );
        MvpSession.rememberPrescriptionSchedules(
          prescriptionId: prescriptionId,
          confirmResponse: response,
          ocrItems: editedItems,
        );
        if (response['dur_result'] is Map) {
          durResult = Map<String, dynamic>.from(response['dur_result'] as Map);
        }
      } else {
        debugPrint(
          '[PRESCRIPTION_DIAG] '
          'prescription_id_present=false schedule_count=unknown',
        );
      }
    } catch (error) {
      debugPrint(
        '[PRESCRIPTION_DIAG] confirm failed error_type=${error.runtimeType}',
      );
      if (!mounted) return;
      showSeniorSnackbar(context, '약 등록에 실패했어요. 잠시 후 다시 시도해 주세요.', error: true);
      return;
    }

    MvpSession.latestOcrItems = editedItems;
    MvpSession.latestOcrRegisteredAt = DateTime.now();
    var refreshFailed = false;
    try {
      await Future.wait<void>([
        ref.read(medicationProvider.notifier).refreshFromServer(),
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
      showSeniorSnackbar(context, '약은 등록됐어요. 목록은 잠시 후 홈에서 다시 불러 주세요.');
    }

    void openScheduleDays() {
      final onOpenScheduleDays = widget.onOpenScheduleDays;
      if (onOpenScheduleDays != null) {
        onOpenScheduleDays();
        return;
      }
      context.push('/schedule-days', extra: MvpSession.latestPrescriptionId);
    }

    if (!_hasPairConflict(durResult)) {
      openScheduleDays();
      return;
    }

    final onCompleted = widget.onCompleted;
    if (onCompleted != null) {
      onCompleted(durResult);
      return;
    }
    context.push(
      '/dur-analysis',
      extra: {...?durResult, 'open_schedule_days': true},
    );
  }

  @override
  Widget build(BuildContext context) {
    switch (_step) {
      case PrescriptionStep.pickMethod:
        return AddMedicineScreen(
          guardianTitle: resolveGuardianTitle(context, widget.guardianTitle),
          onGoHome: widget.onGoHome ?? () => Navigator.of(context).maybePop(),
          onPick: (method) {
            switch (method) {
              case AddMedicineMethod.camera:
                // 카메라를 바로 열지 않고, 찍는 법부터 보여 준다.
                setState(() {
                  _image = null;
                  _step = PrescriptionStep.capture;
                });
              case AddMedicineMethod.gallery:
                _pick(ImageSource.gallery);
              case AddMedicineMethod.manual:
                setState(() => _step = PrescriptionStep.manual);
              case AddMedicineMethod.family:
                break;
            }
          },
        );
      case PrescriptionStep.manual:
        return ManualMedicineScreen(
          onBack: () => setState(() => _step = PrescriptionStep.pickMethod),
          onSaved: (durResult) {
            final onCompleted = widget.onCompleted;
            if (_hasPairConflict(durResult) && onCompleted != null) {
              onCompleted(durResult);
              return;
            }
            final onOpenScheduleDays = widget.onOpenScheduleDays;
            if (onOpenScheduleDays != null) {
              onOpenScheduleDays();
              return;
            }
            if (_hasPairConflict(durResult)) {
              context.push(
                '/dur-analysis',
                extra: {...?durResult, 'open_schedule_days': true},
              );
              return;
            }
            context.push(
              '/schedule-days',
              extra: MvpSession.latestPrescriptionId,
            );
          },
        );
      case PrescriptionStep.capture:
        return _CaptureScreen(
          image: _image,
          onBehalfOf: widget.onBehalfOf,
          onBack: () => setState(() {
            _image = null;
            _step = PrescriptionStep.pickMethod;
          }),
          onUse: _read,
          onCamera: () => _pick(ImageSource.camera),
        );
      case PrescriptionStep.reading:
        return _ReadingScreen(image: _image);
      case PrescriptionStep.confirm:
        return _ConfirmScreen(
          onBehalfOf: widget.onBehalfOf,
          items: _items,
          unrecognizedNames: _unrecognizedNames,
          onRegister: _register,
          onRetake: () => setState(() {
            _image = null;
            _step = PrescriptionStep.pickMethod;
          }),
        );
      case PrescriptionStep.failed:
        return _FailedScreen(
          failureCount: _failureCount,
          failureReason: _failureReason,
          onRetry: () => setState(() {
            _image = null;
            _failureReason = '';
            _step = PrescriptionStep.pickMethod;
          }),
          onAskFamily: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const FirstRunScreen()),
          ),
        );
    }
  }
}

// ════════════════════════════════════════════════════════════════
//  4d — 처방전 촬영
// ════════════════════════════════════════════════════════════════
class _CaptureScreen extends StatelessWidget {
  final File? image;
  final VoidCallback onUse;
  final VoidCallback onCamera;
  final VoidCallback onBack;
  final String? onBehalfOf;

  const _CaptureScreen({
    required this.image,
    required this.onBack,
    this.onBehalfOf,
    required this.onUse,
    required this.onCamera,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.cameraBg,
      body: Column(
        children: [
          SeniorBackHeader(title: '처방전 찍기', onDark: true, onBack: onBack),
          if (onBehalfOf != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 4, 22, 0),
              child: _OnBehalfBanner(title: onBehalfOf!),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      children: [
                        if (image != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(22, 18, 22, 8),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(22),
                              child: AspectRatio(
                                aspectRatio: 3 / 4,
                                child: Image.file(image!, fit: BoxFit.contain),
                              ),
                            ),
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.fromLTRB(22, 18, 22, 8),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.fromLTRB(
                                22,
                                22,
                                22,
                                20,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.darkSurface,
                                borderRadius: BorderRadius.circular(22),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '이렇게 찍어 주세요',
                                    style: AppText.emphasis(
                                      size: 26,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const SizedBox(height: 18),
                                  _CaptureTip(
                                    number: '1',
                                    text: '밝은 곳에 처방전이\n잘 보이게 펼쳐 놓으세요',
                                  ),
                                  const _CaptureTipArrow(),
                                  _CaptureTip(
                                    number: '2',
                                    text: '종이 네 모서리가\n사진에 다 나오게 하세요',
                                  ),
                                  const _CaptureTipArrow(),
                                  _CaptureTip(
                                    number: '3',
                                    text: '두 손으로 잡고\n흔들리지 않게 찍으세요',
                                  ),
                                ],
                              ),
                            ),
                          ),
                        const Spacer(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
                          child: Column(
                            children: [
                              if (image != null) ...[
                                SeniorButton(
                                  label: '이 사진 사용하기',
                                  minHeight: 74,
                                  fontSize: 25,
                                  onPressed: onUse,
                                ),
                                const SizedBox(height: 14),
                              ],
                              SeniorButton(
                                label: image == null ? '사진 찍기' : '다시 찍기',
                                icon: TablerIcons.camera,
                                minHeight: 74,
                                fontSize: 25,
                                onPressed: onCamera,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SafeArea(top: false, child: SizedBox(height: 12)),
        ],
      ),
    );
  }
}

/// "어머니 · 김복자 대신 등록". 누구 약을 넣고 있는지 화면 위에 붙여 둔다.
class _OnBehalfBanner extends StatelessWidget {
  final String title;

  const _OnBehalfBanner({required this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: AppColors.point,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const ExcludeSemantics(
            child: Icon(TablerIcons.users, size: 26, color: Colors.white),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              '$title 대신 등록',
              style: AppText.button(size: 21, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptureTip extends StatelessWidget {
  final String number;
  final String text;

  const _CaptureTip({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.point,
            shape: BoxShape.circle,
          ),
          child: Text(
            number,
            style: AppText.button(size: 22, color: Colors.white),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            text,
            style: AppText.body(
              size: 22,
              color: Colors.white,
              weight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

class _CaptureTipArrow extends StatelessWidget {
  const _CaptureTipArrow();

  @override
  Widget build(BuildContext context) {
    // 긴 화살표를 번호 동그라미(40px) 바로 아래, 같은 세로줄에 둔다.
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      // 화살표 그림(48)이 동그라미 칸(40)보다 넓어, 넘치는 만큼 양쪽으로
      // 고르게 나눠 동그라미 중심과 같은 세로줄에 맞춘다.
      child: SizedBox(
        width: 40,
        height: 48,
        child: OverflowBox(
          maxWidth: 48,
          child: Icon(
            TablerIcons.arrow_narrow_down,
            size: 48,
            color: AppColors.onDarkMuted,
          ),
        ),
      ),
    );
  }
}

class _ReadingScreen extends StatelessWidget {
  final File? image;
  const _ReadingScreen({required this.image});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const SeniorBackHeader(title: '처방전 읽는 중'),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 44,
                      height: 44,
                      child: CircularProgressIndicator(
                        strokeWidth: 4,
                        color: AppColors.point,
                      ),
                    ),
                    const SizedBox(height: 22),
                    Text(
                      '처방전을 읽고 있어요',
                      textAlign: TextAlign.center,
                      style: AppText.emphasis(),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '잠시만 기다려 주세요. 다 읽으면 약 이름을 보여드릴게요.',
                      textAlign: TextAlign.center,
                      style: AppText.body(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
//  4e — 이렇게 읽었어요
// ════════════════════════════════════════════════════════════════
class _ConfirmScreen extends StatefulWidget {
  /// 보호자가 대신 넣을 때 그 어르신 호칭.
  final String? onBehalfOf;

  final List<Map<String, dynamic>> items;
  final List<String> unrecognizedNames;
  final Future<void> Function(List<Map<String, dynamic>> items) onRegister;
  final VoidCallback onRetake;

  const _ConfirmScreen({
    this.onBehalfOf,
    required this.items,
    required this.unrecognizedNames,
    required this.onRegister,
    required this.onRetake,
  });

  @override
  State<_ConfirmScreen> createState() => _ConfirmScreenState();
}

class _ConfirmScreenState extends State<_ConfirmScreen> {
  late final List<Map<String, dynamic>> _editedItems = [
    for (final item in widget.items) Map<String, dynamic>.from(item),
  ];

  bool _registering = false;

  /// 복용 정보 고치기 창에서 돋보기로 고른 공식 약. 저장할 때 함께 넣는다.
  Map<String, dynamic>? _pickedOfficial;
  final Set<int> _expandedItems = <int>{};

  static String _frequencyLabel(Map<String, dynamic> item) {
    final value = item['frequency_per_day'];
    return value is num && value > 0 ? '${value.toInt()}회' : '확인 필요';
  }

  static String _durationLabel(Map<String, dynamic> item) {
    final value = item['duration_days'];
    return value is num && value > 0 ? '${value.toInt()}일' : '확인 필요';
  }

  static String _takeAmountLabel(Map<String, dynamic> item) {
    final canonicalAmount = item['dose_amount']?.toString().trim() ?? '';
    final canonicalUnit = item['dose_unit']?.toString().trim() ?? '';
    final raw = canonicalAmount.isNotEmpty
        ? canonicalAmount
        : item['dosage']?.toString().trim() ?? '';
    final unit = canonicalUnit.isNotEmpty
        ? canonicalUnit
        : item['unit']?.toString().trim() ?? '';
    if (RegExp(
      r'(mg|ml|g|%|밀리그램|밀리그람)(?:\s*$|[),/])',
      caseSensitive: false,
    ).hasMatch(raw)) {
      return '';
    }
    final compact = raw.replaceAll(RegExp(r'\s+'), '');
    final half = RegExp(
      r'^반(알|정|캡슐|포|개)$',
      caseSensitive: false,
    ).firstMatch(compact);
    if (half != null) {
      final normalized = half.group(1) == '알' ? '정' : half.group(1)!;
      return '0.5$normalized';
    }
    final fraction = RegExp(
      r'^(\d+)/(\d+)(알|정|캡슐|포|개|mL|ml|방울|T|TAB|C|CAP|PKG|EA)$',
      caseSensitive: false,
    ).firstMatch(compact);
    if (fraction != null) {
      final denominator = int.tryParse(fraction.group(2)!);
      final numerator = int.tryParse(fraction.group(1)!);
      if (denominator != null && denominator != 0 && numerator != null) {
        final normalizedItem = Map<String, dynamic>.from(item)
          ..['dosage'] = (numerator / denominator).toString()
          ..['unit'] = fraction.group(3);
        return _takeAmountLabel(normalizedItem);
      }
    }
    final match = RegExp(
      r'^(\d+(?:\.\d+)?)(알|정|캡슐|포|개|mL|ml|방울|T|TAB|C|CAP|PKG|EA)$',
      caseSensitive: false,
    ).firstMatch(compact);
    final number =
        match?.group(1) ?? (double.tryParse(compact) != null ? compact : null);
    final rawUnit = match?.group(2) ?? unit;
    if (number == null) return '';
    final parsed = double.tryParse(number);
    final amount = parsed == null
        ? number
        : parsed == parsed.roundToDouble()
        ? parsed.toInt().toString()
        : parsed
              .toStringAsFixed(3)
              .replaceFirst(RegExp(r'0+$'), '')
              .replaceFirst(RegExp(r'\.$'), '');
    final normalizedUnit = switch (rawUnit.toUpperCase()) {
      'T' || 'TAB' || '정' || '알' => '정',
      'C' || 'CAP' || '캡슐' => '캡슐',
      'PKG' || '포' => '포',
      'EA' || '개' => '개',
      'ML' || '밀리리터' => 'mL',
      '방울' => '방울',
      _ => '',
    };
    return normalizedUnit.isEmpty
        ? '$amount · 단위 확인 필요'
        : '$amount$normalizedUnit';
  }

  static String _shortDrugName(String name) {
    return stripExportAlias(name);
  }

  static String? _seniorExplanation(Map<String, dynamic> item) {
    final raw =
        item['short_explanation']?.toString().trim() ??
        item['easy_explanation']?.toString().trim() ??
        item['easy_category']?.toString().trim() ??
        '';
    if (raw.isEmpty || raw == '처방받은 약이에요') return null;
    return raw;
  }

  static Map<String, int> _fieldConfidences(Map<String, dynamic> item) {
    final raw = item['ocr_field_confidences'];
    if (raw is! Map) return const {};
    return {
      for (final entry in raw.entries)
        if (entry.value is num)
          entry.key.toString(): (entry.value as num).round(),
    };
  }

  static String _matchStatusLabel(Map<String, dynamic> item) {
    final status = item['match_status']?.toString().toUpperCase() ?? '';
    return switch (status) {
      'MATCHED' || 'MFDS' => '공식 약 확인됨',
      'REVIEW_REQUIRED' => '약 확인 필요',
      _ => '공식 약을 찾지 못함',
    };
  }

  static bool _uncertain(Map<String, dynamic> item) {
    if (item['uncertain'] == true) return true;
    if (item['match_status']?.toString() == 'UNMATCHED') return true;
    final confidence = item['confidence'];
    return confidence is num && confidence < 0.7;
  }

  static List<Map<String, String>> _interactionConflicts(
    Map<String, dynamic> item,
  ) {
    final raw = item['interaction_conflicts'];
    if (raw is! List) return const [];
    return [
      for (final row in raw)
        if (row is Map)
          {
            'other_name': _shortDrugName(row['other_name']?.toString() ?? ''),
            'reason': row['reason']?.toString() ?? '',
          },
    ].where((row) => row['other_name']!.isNotEmpty).toList();
  }

  Future<void> _editItem(int index) async {
    final item = _editedItems[index];
    final canonicalAmount = item['dose_amount']?.toString().trim() ?? '';
    final existingDosage = item['dosage']?.toString().trim() ?? '';
    final timesPerTake = item['times_per_take'];
    final amountMatch = RegExp(
      r'^(\d+(?:\.\d+)?)\s*(알|정|캡슐|포|개|mL|ml|방울|T|TAB|C|CAP|PKG|EA)?$',
      caseSensitive: false,
    ).firstMatch(existingDosage);
    final amountController = TextEditingController(
      text: canonicalAmount.isNotEmpty
          ? canonicalAmount
          : amountMatch?.group(1) != null
          ? amountMatch!.group(1)!
          : (timesPerTake is num && timesPerTake > 0
                ? timesPerTake.toString()
                : ''),
    );
    String? doseUnit = _editableDoseUnit(
      item['dose_unit']?.toString() ??
          item['unit']?.toString() ??
          amountMatch?.group(2) ??
          '',
    );
    final duration = item['duration_days'];
    final durationController = TextEditingController(
      text: duration is num && duration > 0 ? duration.toInt().toString() : '',
    );
    final rawFrequency = item['frequency_per_day'];
    final frequencyController = TextEditingController(
      text: rawFrequency is num && rawFrequency > 0
          ? rawFrequency.toInt().toString()
          : '',
    );

    // 자판 대신 ─/＋ 로 고친다. 숫자를 지우고 다시 치는 일이 없다.
    var amount = int.tryParse(amountController.text.trim()) ?? 1;
    var frequency = int.tryParse(frequencyController.text.trim());
    var days = int.tryParse(durationController.text.trim());
    final nameController = TextEditingController(
      text: item['drug_name']?.toString() ?? '',
    );

    // 돋보기 — 적어 넣은 이름을 공식 의약품 목록에서 찾는다.
    Future<void> searchName(BuildContext sheetContext) async {
      final query = nameController.text.trim();
      if (query.length < 2) {
        showSeniorSnackbar(sheetContext, '약 이름을 두 글자 이상 적어 주세요.', error: true);
        return;
      }
      final picked = await _lookupOfficialMedicine(query);
      if (picked == null || !sheetContext.mounted) return;
      final displayName =
          picked['display_name']?.toString() ??
          picked['product_name']?.toString() ??
          query;
      nameController.text = displayName;
      _pickedOfficial = picked;
    }

    await SeniorSheet.show<void>(
      context: context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SeniorSheet(
          title: '복용 정보 고치기',
          bodyGap: 6,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('약 이름', style: AppText.label(size: 18)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: SeniorField(
                      controller: nameController,
                      hint: '약 이름',
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => searchName(sheetContext),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Semantics(
                    button: true,
                    label: '약 이름 찾기',
                    child: ExcludeSemantics(
                      child: GestureDetector(
                        onTap: () => searchName(sheetContext),
                        child: Container(
                          width: 66,
                          height: 66,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppColors.point,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            TablerIcons.search,
                            size: 30,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _Stepper(
                label: '한 번에 몇 알',
                value: '$amount${doseUnit ?? '알'}',
                onMinus: amount > 1
                    ? () => setSheetState(() => amount -= 1)
                    : null,
                onPlus: amount < 10
                    ? () => setSheetState(() => amount += 1)
                    : null,
              ),
              const SizedBox(height: 16),
              _Stepper(
                label: '하루 몇 번',
                value: frequency == null ? '확인 필요' : '$frequency번',
                needsConfirmation: frequency == null,
                onMinus: frequency == null
                    ? null
                    : () => setSheetState(
                        () =>
                            frequency = frequency! > 1 ? frequency! - 1 : null,
                      ),
                onPlus: () => setSheetState(
                  () => frequency = frequency == null
                      ? 1
                      : (frequency! < 6 ? frequency! + 1 : frequency),
                ),
              ),
              const SizedBox(height: 16),
              _Stepper(
                label: '며칠분',
                value: days == null ? '확인 필요' : '$days일',
                needsConfirmation: days == null,
                onMinus: days == null
                    ? null
                    : () => setSheetState(
                        () => days = days! > 1 ? days! - 1 : null,
                      ),
                onPlus: () => setSheetState(
                  () => days = days == null
                      ? 1
                      : (days! < 365 ? days! + 1 : days),
                ),
              ),
            ],
          ),
          actions: [
            SeniorButton(
              label: '이 정보로 하기',
              minHeight: 68,
              onPressed: () {
                final picked = _pickedOfficial;
                final typedName = nameController.text.trim();
                setState(() {
                  _editedItems[index] = {
                    ...item,
                    if (typedName.isNotEmpty) 'drug_name': typedName,
                    if (typedName.isNotEmpty) 'display_name': typedName,
                    if (picked != null) ...{
                      'medicine_code': picked['medicine_code'],
                      'official_product_name':
                          picked['product_name']?.toString() ?? typedName,
                      'ingredient_name':
                          picked['ingredient_name']?.toString() ??
                          picked['ingredient']?.toString() ??
                          '',
                      'match_status': 'MATCHED',
                    },
                    'dose_amount': '$amount',
                    'dose_unit': doseUnit,
                    'dosage': '$amount${doseUnit ?? '정'}',
                    'unit': doseUnit,
                    'times_per_take': null,
                    'frequency_per_day': frequency,
                    'duration_days': days,
                  };
                });
                Navigator.of(sheetContext).pop();
              },
            ),
          ],
        ),
      ),
    );
    amountController.dispose();
    frequencyController.dispose();
    durationController.dispose();
  }

  static String? _editableDoseUnit(String raw) {
    return switch (raw.trim().toUpperCase()) {
      'T' || 'TAB' || '정' || '알' => '정',
      'C' || 'CAP' || '캡슐' => '캡슐',
      'PKG' || '포' => '포',
      'ML' || '밀리리터' => 'mL',
      '방울' => '방울',
      'EA' || '개' => '개',
      _ => null,
    };
  }

  /// 적어 넣은 이름으로 공식 의약품 목록을 찾고, 하나를 고르게 한다.
  Future<Map<String, dynamic>?> _lookupOfficialMedicine(String query) async {
    try {
      final response = await ApiClient(
        baseUrl: ApiConfig.localFeatureBaseUrl,
      ).get('/api/v1/medicines/lookup?q=${Uri.encodeQueryComponent(query)}');
      if (!mounted) return null;
      final rawItems = response is Map ? response['items'] : null;
      final hits = rawItems is List
          ? rawItems
                .whereType<Map>()
                .map((value) => Map<String, dynamic>.from(value))
                .toList()
          : <Map<String, dynamic>>[];
      if (hits.isEmpty) {
        showSeniorSnackbar(context, '공식 의약품 목록에서 해당 이름을 찾지 못했어요.', error: true);
        return null;
      }
      return await _pickOfficialMedicine(hits);
    } catch (_) {
      if (!mounted) return null;
      showSeniorSnackbar(
        context,
        '약 이름을 찾지 못했어요. 잠시 후 다시 시도해 주세요.',
        error: true,
      );
      return null;
    }
  }

  Future<void> _fixMedicineName(int index) async {
    final item = _editedItems[index];
    final current =
        item['ocr_drug_name_raw']?.toString().trim().isNotEmpty == true
        ? item['ocr_drug_name_raw'].toString()
        : item['drug_name']?.toString() ?? '';
    final query = await showFixNameSheet(context, current: current);
    if (!mounted || query == null) return;

    try {
      final response = await ApiClient(
        baseUrl: ApiConfig.localFeatureBaseUrl,
      ).get('/api/v1/medicines/lookup?q=${Uri.encodeQueryComponent(query)}');
      if (!mounted) return;
      final rawItems = response is Map ? response['items'] : null;
      final hits = rawItems is List
          ? rawItems
                .whereType<Map>()
                .map((value) => Map<String, dynamic>.from(value))
                .toList()
          : <Map<String, dynamic>>[];
      if (hits.isEmpty) {
        showSeniorSnackbar(context, '공식 의약품 목록에서 해당 이름을 찾지 못했어요.', error: true);
        return;
      }
      final picked = await _pickOfficialMedicine(hits);
      if (!mounted || picked == null) return;
      final displayName =
          picked['display_name']?.toString() ??
          picked['product_name']?.toString() ??
          query;
      setState(() {
        _editedItems[index] = {
          ...item,
          'medicine_code': picked['medicine_code'],
          'drug_name': displayName,
          'display_name': displayName,
          'official_product_name':
              picked['product_name']?.toString() ?? displayName,
          'ingredient_name':
              picked['ingredient_name']?.toString() ??
              picked['ingredient']?.toString() ??
              '',
          'ocr_drug_name_raw': current,
          'match_status': 'MATCHED',
        };
        _expandedItems.add(index);
      });
    } catch (_) {
      if (!mounted) return;
      showSeniorSnackbar(
        context,
        '공식 약을 찾지 못했어요. 잠시 후 다시 시도해 주세요.',
        error: true,
      );
    }
  }

  Future<Map<String, dynamic>?> _pickOfficialMedicine(
    List<Map<String, dynamic>> hits,
  ) {
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bg,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('공식 약을 골라 주세요', style: AppText.emphasis(size: 24)),
              const SizedBox(height: 6),
              Text(
                '제품명과 주성분을 처방전과 비교해 주세요.',
                style: AppText.body(size: 17, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: hits.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final hit = hits[index];
                    final name =
                        hit['display_name']?.toString() ??
                        hit['product_name']?.toString() ??
                        '약';
                    final ingredient =
                        hit['ingredient_name']?.toString() ??
                        hit['ingredient']?.toString() ??
                        '';
                    return SeniorCard(
                      onTap: () => Navigator.of(sheetContext).pop(hit),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name, style: AppText.cardTitle(size: 20)),
                          if (ingredient.trim().isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              '주성분: $ingredient',
                              style: AppText.caption(
                                size: 17,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmPartialRegistration() async {
    if (widget.unrecognizedNames.isEmpty) return true;
    return showSeniorYesNoDialog(
      context: context,
      title: '확인하지 못한 약이 있어요',
      message:
          '제외한 약은 함께 먹기 확인에서도 빠져요. '
          '처방전과 비교한 뒤 제외하고 등록해 주세요.',
      yesLabel: '제외하고 등록',
      noLabel: '다시 확인하기',
    );
  }

  Future<void> _tryRegister() async {
    if (_registering) return;
    if (!await _confirmPartialRegistration()) return;
    setState(() => _registering = true);
    try {
      await widget.onRegister(_editedItems);
    } finally {
      if (mounted) setState(() => _registering = false);
    }
  }

  /// 등록 뒤 홈에서 본 것과 다른 화면으로 읽힌다.
  List<Widget> _tomorrowPreview() {
    final bySlot = <String, int>{};
    for (final item in _editedItems) {
      final times = item['administration_times'];
      if (times is! List) continue;
      for (final raw in times) {
        final label = _slotLabel(raw?.toString() ?? '');
        if (label == null) continue;
        bySlot[label] = (bySlot[label] ?? 0) + 1;
      }
    }
    // 시간대를 못 읽었으면 미리보기를 만들지 않는다. 지어낸 시각을
    // 보여주면 그 시각에 드시게 된다.
    if (bySlot.isEmpty) return const [];

    const order = ['아침 8시', '점심 12시', '저녁 6시', '자기 전'];
    final rows = <Widget>[];
    final labels = order.where(bySlot.containsKey).toList();
    for (int i = 0; i < labels.length; i++) {
      rows.add(
        TimelineRow(
          first: i == 0,
          last: i == labels.length - 1,
          // 여백을 행 안에 두어야 축선이 카드 사이에서 끊기지 않는다.
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: SeniorCard(
              radius: 20,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              child: Text(
                '${labels[i]} · ${bySlot[labels[i]]}알',
                style: AppText.cardTitle(size: 19),
              ),
            ),
          ),
        ),
      );
    }

    return [
      Text('내일부터 이렇게 됩니다', style: AppText.cardTitle(size: 20)),
      const SizedBox(height: 12),
      ...rows,
      const SizedBox(height: 12),
    ];
  }

  /// 서버가 주는 복용 시간을 화면 문구로. 모르면 null.
  static String? _slotLabel(String raw) {
    final text = raw.toLowerCase();
    if (text.contains('아침') || text.contains('morning')) return '아침 8시';
    if (text.contains('점심') ||
        text.contains('lunch') ||
        text.contains('noon')) {
      return '점심 12시';
    }
    if (text.contains('저녁') ||
        text.contains('evening') ||
        text.contains('dinner')) {
      return '저녁 6시';
    }
    if (text.contains('자기') || text.contains('night') || text.contains('bed')) {
      return '자기 전';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const SeniorBackHeader(title: '이렇게 읽었어요'),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.onBehalfOf != null) ...[
                    _OnBehalfBanner(title: widget.onBehalfOf!),
                    const SizedBox(height: 12),
                  ],
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 18,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.point, width: 2),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _editedItems.isEmpty
                              ? '글자는 읽었는데, 공식 약과 아직 못 맞췄어요'
                              : '약 ${_editedItems.length}가지를 찾았어요',
                          style: AppText.cardTitle(color: AppColors.point),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _editedItems.isEmpty
                              ? '글자는 읽었는데, 공식 약과 아직 못 맞췄어요'
                              : '틀린 곳이 있으면 눌러서 고쳐주세요.',
                          style: AppText.caption(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (int index = 0; index < _editedItems.length; index++) ...[
                    Builder(
                      builder: (context) {
                        final item = _editedItems[index];
                        return _DrugCard(
                          name: _shortDrugName(
                            item['drug_name']?.toString() ?? '이름을 못 읽었어요',
                          ),
                          ingredient:
                              item['ingredient_name']?.toString() ??
                              item['ingredient']?.toString() ??
                              '',
                          ingredientStrength:
                              item['ingredient_strength']?.toString() ?? '',
                          rawOcrName:
                              item['ocr_drug_name_raw']?.toString() ??
                              item['drug_name']?.toString() ??
                              '',
                          officialName:
                              item['official_product_name']?.toString() ??
                              item['drug_name']?.toString() ??
                              '',
                          medicineCode: item['medicine_code']?.toString() ?? '',
                          doseAmount: _takeAmountLabel(item),
                          frequencyPerDay: _frequencyLabel(item),
                          durationDays: _durationLabel(item),
                          purposeLabel: item['purpose_label']?.toString(),
                          explanation: _seniorExplanation(item),
                          keyCaution: item['key_caution']?.toString(),
                          fieldConfidences: _fieldConfidences(item),
                          matchStatusLabel: _matchStatusLabel(item),
                          uncertain: _uncertain(item),
                          conflicts: _interactionConflicts(item),
                          expanded: _expandedItems.contains(index),
                          onToggle: () => setState(() {
                            if (!_expandedItems.remove(index)) {
                              _expandedItems.add(index);
                            }
                          }),
                          onFixName: () => _fixMedicineName(index),
                          onEditDosing: () => _editItem(index),
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (widget.unrecognizedNames.isNotEmpty) ...[
                    SeniorCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 18,
                      ),
                      borderColor: AppColors.attentionBorder,
                      borderWidth: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '읽지 못한 약 이름이 있어요',
                            style: AppText.cardTitle(
                              size: 20,
                              color: AppColors.attentionBorder,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '아래 이름은 등록에서 빼 두었어요. 처방전과 비교하고, 밝은 곳에서 다시 찍어 주세요.',
                            style: AppText.body(size: 18),
                          ),
                          const SizedBox(height: 8),
                          for (final name in widget.unrecognizedNames)
                            Text('· $name (못 읽음)', style: AppText.body()),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_editedItems.isNotEmpty) ..._tomorrowPreview(),
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
                  if (_editedItems.isNotEmpty) ...[
                    SeniorButton(
                      label: _registering
                          ? '보내고 있어요'
                          : (widget.onBehalfOf == null
                                ? '이대로 등록하기'
                                : '어르신께 보내기'),
                      minHeight: 70,
                      onPressed: _registering ? null : _tryRegister,
                    ),
                    SeniorTextButton(
                      label: '다시 찍기',
                      onPressed: widget.onRetake,
                    ),
                  ] else
                    SeniorButton(
                      label: '다시 찍어드릴게요',
                      minHeight: 70,
                      onPressed: widget.onRetake,
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

class _DrugCard extends StatelessWidget {
  final String name;
  final String ingredient;
  final String ingredientStrength;
  final String rawOcrName;
  final String officialName;
  final String medicineCode;
  final String doseAmount;
  final String frequencyPerDay;
  final String durationDays;
  final String? purposeLabel;
  final String? explanation;
  final String? keyCaution;
  final Map<String, int> fieldConfidences;
  final String matchStatusLabel;
  final bool uncertain;
  final List<Map<String, String>> conflicts;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onFixName;
  final VoidCallback onEditDosing;

  const _DrugCard({
    required this.name,
    required this.ingredient,
    required this.ingredientStrength,
    required this.rawOcrName,
    required this.officialName,
    required this.medicineCode,
    required this.doseAmount,
    required this.frequencyPerDay,
    required this.durationDays,
    required this.purposeLabel,
    required this.explanation,
    required this.keyCaution,
    required this.fieldConfidences,
    required this.matchStatusLabel,
    required this.uncertain,
    this.conflicts = const [],
    required this.expanded,
    required this.onToggle,
    required this.onFixName,
    required this.onEditDosing,
  });

  /// 인식·복용 정보 확인은 주황, 실제 약 충돌은 빨강으로 구분한다.
  bool get _needsCheck =>
      uncertain ||
      conflicts.isNotEmpty ||
      doseAmount.isEmpty ||
      doseAmount.contains('확인 필요') ||
      frequencyPerDay == '확인 필요' ||
      durationDays == '확인 필요';

  @override
  Widget build(BuildContext context) {
    return SeniorCard(
      onTap: onToggle,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      borderColor: conflicts.isNotEmpty
          ? AppColors.danger
          : (_needsCheck ? AppColors.attentionBorder : null),
      borderWidth: conflicts.isNotEmpty ? 3 : 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: AppText.cardTitle(size: 21)),
          if (ingredient.trim().isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              '주성분: ${[compactIngredientSummary(ingredient), ingredientStrength].where((value) => value.trim().isNotEmpty).join(' · ')}',
              style: AppText.caption(size: 17, color: AppColors.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (explanation != null && explanation!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              explanation!,
              style: AppText.body(size: 19),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 12),
          _DoseInfoRow(
            label: '1회 투약량',
            value: doseAmount.isEmpty ? '확인 필요' : doseAmount,
            needsConfirmation:
                doseAmount.isEmpty || doseAmount.contains('확인 필요'),
          ),
          const SizedBox(height: 7),
          _DoseInfoRow(
            label: '1일 투여횟수',
            value: frequencyPerDay,
            needsConfirmation: frequencyPerDay == '확인 필요',
          ),
          const SizedBox(height: 7),
          _DoseInfoRow(
            label: '투약일수',
            value: durationDays,
            needsConfirmation: durationDays == '확인 필요',
          ),
          if (uncertain) ...[
            const SizedBox(height: 10),
            Text(
              '약 확인 필요',
              style: AppText.label(size: 17.5, color: AppColors.danger),
            ),
          ],
          if (conflicts.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final conflict in conflicts) ...[
              Text(
                '${conflict['other_name']}과 함께 먹으면 주의가 필요해요',
                style: AppText.label(size: 17.5, color: AppColors.danger),
              ),
              if ((conflict['reason'] ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  conflict['reason']!,
                  style: AppText.body(size: 17, color: AppColors.danger),
                ),
              ],
              const SizedBox(height: 6),
            ],
          ],
          const SizedBox(height: 14),
          SeniorButton(
            label: '복용 정보 고치기',
            kind: SeniorButtonKind.neutral,
            minHeight: 66,
            fontSize: 21,
            onPressed: onEditDosing,
          ),
        ],
      ),
    );
  }
}

/// ─/＋ 로 고치는 한 줄 (프로토타입 "복용 정보 고치기").
///
/// 자판을 띄우지 않는다. 한 번 누를 때마다 한 칸씩 움직인다.
class _Stepper extends StatelessWidget {
  final String label;
  final String value;
  final bool needsConfirmation;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;

  const _Stepper({
    required this.label,
    required this.value,
    this.needsConfirmation = false,
    this.onMinus,
    this.onPlus,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppText.label(size: 18)),
        const SizedBox(height: 8),
        Row(
          children: [
            _StepperButton(
              icon: TablerIcons.minus,
              label: '$label 줄이기',
              onTap: onMinus,
            ),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.center,
                style: AppText.cardTitle(
                  size: 24,
                  color: needsConfirmation
                      ? AppColors.danger
                      : AppColors.textPrimary,
                ),
              ),
            ),
            _StepperButton(
              icon: TablerIcons.plus,
              label: '$label 늘리기',
              onTap: onPlus,
            ),
          ],
        ),
      ],
    );
  }
}

class _StepperButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _StepperButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      label: label,
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 72,
            height: 72,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.secondaryFill,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppColors.strongLine, width: 2),
            ),
            child: Icon(
              icon,
              size: 32,
              color: enabled ? AppColors.textBody : AppColors.inactive,
            ),
          ),
        ),
      ),
    );
  }
}

class _DoseInfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool needsConfirmation;

  const _DoseInfoRow({
    required this.label,
    required this.value,
    this.needsConfirmation = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 128,
          child: Text(
            label,
            style: AppText.label(size: 17, color: AppColors.textSecondary),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: AppText.label(
              size: 18,
              color: needsConfirmation
                  ? AppColors.danger
                  : AppColors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

class _FailedScreen extends StatelessWidget {
  final int failureCount;
  final String failureReason;
  final VoidCallback onRetry;
  final VoidCallback onAskFamily;

  const _FailedScreen({
    required this.failureCount,
    required this.failureReason,
    required this.onRetry,
    required this.onAskFamily,
  });

  @override
  Widget build(BuildContext context) {
    final tooManyTries = failureCount >= 3;
    final connectionFail =
        failureReason.contains('연결') ||
        failureReason.contains('Socket') ||
        failureReason.contains('Timeout') ||
        failureReason.contains('timeout');
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const SeniorBackHeader(title: '처방전 찍기'),
          Expanded(
            child: RecoveryView(
              title: '지금은 처방전을\n읽지 못하고 있어요',
              reassurance: connectionFail
                  ? '서버에 연결하지 못했어요. 같은 와이파이인지, 서버가 켜져 있는지 봐 주세요. '
                  : (failureReason.isEmpty
                        ? '흐리거나 흔들리면 약 이름이 잘려 버려질 수 있어요. '
                        : '$failureReason '),
              reassuranceEmphasis: '잘못 찍으신 게 아니니 걱정하지 마세요.',
              steps: const [
                '밝은 곳에 처방전을 펼쳐 놓으세요',
                '종이 네 귀퉁이가 다 보이게 하세요',
                '전화기를 두 손으로 잡고 흔들리지 않게 찍으세요',
                '다시 찍기, 앨범에서 고르기, 직접 입력 중에서 고를 수 있어요',
              ],
              actionLabel: '다시 찍어드릴게요',
              onAction: onRetry,
              stillWorksTitle: '지금 드시는 약은 그대로예요',
              stillWorksBody: '이미 등록된 약과 알림은 아무 영향이 없어요.',
              helperText: tooManyTries ? '어려우시면\n가족이 대신 찍어드릴 수 있어요' : null,
              onCallHelper: tooManyTries ? onAskFamily : null,
            ),
          ),
        ],
      ),
    );
  }
}
