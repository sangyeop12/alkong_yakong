import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_config.dart';
import '../../core/session/mvp_session.dart';
import '../../core/theme/app_typography.dart';
import '../../core/widgets/senior_button.dart';
import '../../core/widgets/senior_card.dart';
import '../../core/widgets/senior_feedback.dart';
import '../../core/widgets/senior_header.dart';
import '../../core/widgets/senior_sheet.dart';
import '../../core/widgets/senior_wheel.dart';
import '../medicines/domain/display_policy.dart';

class DrugExplainScreen extends StatefulWidget {
  final ApiClient? apiClient;
  final ApiClient? medicationApiClient;

  const DrugExplainScreen({
    super.key,
    this.apiClient,
    this.medicationApiClient,
  });

  @override
  State<DrugExplainScreen> createState() => _DrugExplainScreenState();
}

class _DrugExplainScreenState extends State<DrugExplainScreen>
    with WidgetsBindingObserver {
  late final ApiClient _apiClient;
  late final ApiClient _medicationApiClient;
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _chatFocusNode = FocusNode();

  bool _isLoading = false;
  bool _isLoadingMedicines = false;
  String? _selectedKeyword;
  final List<String> _selectedMedicines = [];
  String? _pendingGeneralQuestion;
  bool _isAllMedicinesSelected = false;
  final Map<String, _DrugSearchCandidate> _officialMedicinesByName = {};
  final Set<String> _confirmedOfficialProductNames = {};
  final Map<String, _DrugSearchCandidate> _temporaryMedicinesByCode = {};
  String? _medicineLoadError;
  final List<String> _medicines = [];
  final List<Map<String, dynamic>> _messages = [];

  String? get _selectedMedicine =>
      _selectedMedicines.length == 1 ? _selectedMedicines.single : null;

  bool get _hasMultipleMedicines => _selectedMedicines.length >= 2;

  List<String> get _selectedRequestMedicineNames => _selectedMedicines
      .map((name) => _officialMedicinesByName[name]?.itemName ?? name)
      .toList(growable: false);

  _DrugSearchCandidate? get _selectedOfficialMedicine {
    final medicine = _selectedMedicine;
    return medicine == null ? null : _officialMedicinesByName[medicine];
  }

  static const List<Map<String, String>> _suggestions = [
    {
      'label': '이 약은 무슨 약이에요?',
      'prompt': '{medicine}이 무슨 약인지 쉬운 말로 알려주세요.',
      'intent': 'overview',
    },
    {
      'label': '언제 어떻게 사용하나요?',
      'prompt': '{medicine}을 언제 어떻게 사용하는지 쉬운 말로 알려주세요.',
      'intent': 'dosage',
    },
  ];

  /// 약을 선택한 뒤 여섯 가지 질문 중 필요한 것을 고른다.
  static const List<Map<String, String>> _keywordPrompts = [
    {
      'label': '어디에 쓰는 약인가요?',
      'prompt': '이 약은 어디에 쓰는 약인가요?',
      'intent': 'efficacy',
    },
    {
      'label': '어떻게 사용하나요?',
      'prompt': '이 약은 보통 어떻게 사용하나요? 제가 등록한 사용 방법과 제품의 일반적인 사용법을 구분해서 알려주세요.',
      'display': '이 약은 보통 어떻게 사용하나요?',
      'intent': 'dosage',
    },
    {
      'label': '무엇을 조심해야 하나요?',
      'prompt': '이 약을 사용할 때 무엇을 조심해야 하나요?',
      'intent': 'precautions',
    },
    {
      'label': '사용 뒤 증상이 생기면?',
      'prompt': '이 약을 사용한 뒤 평소와 다른 증상이 생기면 어떻게 해야 하나요?',
      'intent': 'side_effects',
    },
    {
      'label': '나이에 따라 조심할 점',
      'prompt': '제 나이에 이 약을 사용할 때 조심할 점이 있나요?',
      'intent': 'age',
    },
    {
      'label': '임신 중에 조심할 점',
      'prompt': '임신 중에 이 약을 사용할 때 조심할 점이 있나요?',
      'intent': 'pregnancy',
    },
  ];

  static const List<Map<String, String>> _allMedicinePrompts = [
    {
      'label': '제가 먹는 약 알려주세요',
      'prompt': '제가 현재 먹는 약 전체를 쉬운 말로 알려주세요.',
      'display': '제가 먹는 약 알려주세요',
      'intent': 'overview',
    },
    {
      'label': '같이 먹어도 괜찮나요?',
      'prompt': '제가 현재 먹는 약 전체를 같이 먹을 때 주의할 점이 있는지 확인해 주세요.',
      'display': '같이 먹어도 괜찮나요?',
      'intent': 'combination',
    },
    {
      'label': '같은 성분의 약이 있나요?',
      'prompt': '제가 현재 먹는 약 전체에서 같은 성분이나 비슷한 역할이 겹치는 약이 있는지 확인해 주세요.',
      'display': '같은 성분의 약이 있나요?',
      'intent': 'duplicate',
    },
    {
      'label': '약마다 주의할 점은요?',
      'prompt': '제가 현재 먹는 약마다 공식 자료에서 확인되는 주의할 점을 알려주세요.',
      'display': '약마다 주의할 점은요?',
      'intent': 'precautions',
    },
  ];

  static const List<Map<String, String>> _selectedMedicinePrompts = [
    {
      'label': '선택한 약 알려주세요',
      'prompt': '{medicines} 각각이 무슨 약인지 쉬운 말로 알려주세요.',
      'display': '선택한 약 알려주세요',
      'intent': 'overview',
    },
    {
      'label': '같이 먹어도 괜찮나요?',
      'prompt': '{medicines}을 함께 사용할 때 주의할 점이 있는지 확인해 주세요.',
      'display': '같이 먹어도 괜찮나요?',
      'intent': 'combination',
    },
    {
      'label': '같은 성분의 약이 있나요?',
      'prompt': '{medicines} 사이에 같은 성분이나 비슷한 역할이 겹치는지 확인해 주세요.',
      'display': '같은 성분의 약이 있나요?',
      'intent': 'duplicate',
    },
    {
      'label': '약마다 주의할 점은요?',
      'prompt': '{medicines} 각각의 공식 자료에서 확인되는 주의할 점을 알려주세요.',
      'display': '약마다 주의할 점은요?',
      'intent': 'precautions',
    },
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _apiClient = widget.apiClient ?? ApiClient();
    _medicationApiClient =
        widget.medicationApiClient ??
        ApiClient(baseUrl: ApiConfig.localFeatureBaseUrl);
    // 초기 안내 메시지 추가
    _messages.add({
      'isMe': false,
      'text': '안녕하세요, 선생님! 약에 대해 궁금한 것을 편하게 물어보세요.\n어려운 말은 쉬운 말로 바꿔서 알려드릴게요.',
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMedicines());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _chatController.dispose();
    _scrollController.dispose();
    _chatFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (_chatFocusNode.hasFocus) _scrollToBottom();
  }

  Future<void> _selectKeyword(Map<String, String> keyword) async {
    if (_isLoading) return;

    final label = keyword['label'];
    final prompt = keyword['prompt'];
    final intent = keyword['intent'];
    if (label == null || prompt == null || intent == null) return;

    if (_isAllMedicinesSelected && !_allMedicinePrompts.contains(keyword)) {
      return;
    }
    if (_hasMultipleMedicines && !_selectedMedicinePrompts.contains(keyword)) {
      return;
    }
    if (!_isAllMedicinesSelected && _selectedMedicines.isEmpty) return;

    final requestPrompt = _hasMultipleMedicines
        ? prompt.replaceAll(
            '{medicines}',
            _selectedRequestMedicineNames.join(', '),
          )
        : prompt;

    setState(() => _selectedKeyword = label);
    await _sendMessage(
      message: requestPrompt,
      displayMessage: keyword['display'] ?? requestPrompt,
      intent: intent,
    );
  }

  Future<void> _loadMedicines() async {
    final names = <String>[];
    final officialMedicines = <String, _DrugSearchCandidate>{};
    final ambiguousNames = <String>{};
    final namesByCode = <String, String>{};
    final officialNamesByCode = <String, String>{};
    final namesByNormalizedName = <String, String>{};

    String firstText(Iterable<dynamic> values) {
      for (final value in values) {
        final text = value?.toString().trim() ?? '';
        if (text.isNotEmpty) return text;
      }
      return '';
    }

    void addName(dynamic value) {
      final name = value?.toString().trim() ?? '';
      if (name.isNotEmpty && !names.contains(name)) names.add(name);
    }

    void addMedicine(dynamic nameValue, dynamic codeValue, {String? label}) {
      final officialName = nameValue?.toString().trim() ?? '';
      final name = (label ?? officialName).trim();
      final code = codeValue?.toString().trim() ?? '';
      if (code.isNotEmpty) {
        if (officialName.isNotEmpty) officialNamesByCode[code] = officialName;
        final oldName = namesByCode[code];
        if (oldName != null && oldName != name) {
          names.remove(oldName);
          officialMedicines.remove(oldName);
        }
        namesByCode[code] = name;
      } else if (name.isNotEmpty) {
        final normalizedName = name
            .replaceAll(RegExp(r'\s+'), '')
            .toLowerCase();
        if (namesByNormalizedName.containsKey(normalizedName)) return;
        namesByNormalizedName[normalizedName] = name;
      }
      addName(name);
      if (name.isEmpty ||
          officialName.isEmpty ||
          code.isEmpty ||
          ambiguousNames.contains(name)) {
        return;
      }
      final existing = officialMedicines[name];
      if (existing != null && existing.itemSeq != code) {
        officialMedicines.remove(name);
        ambiguousNames.add(name);
        return;
      }
      officialMedicines[name] = _DrugSearchCandidate(
        itemName: officialName,
        itemSeq: code,
      );
    }

    for (final item in MvpSession.latestOcrItems) {
      final officialName = firstText([
        item['official_product_name'],
        item['product_name'],
      ]);
      final label = firstText([
        item['medicine_name'],
        item['drug_name'],
        item['ocr_drug_name'],
        officialName,
      ]);
      addMedicine(
        officialName,
        officialName.isEmpty
            ? null
            : item['medicine_code'] ?? item['item_seq'] ?? item['itemSeq'],
        label: label,
      );
    }

    final userId = MvpSession.userId.trim();
    if (userId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _medicines
          ..clear()
          ..addAll(names);
        _officialMedicinesByName
          ..clear()
          ..addAll(officialMedicines);
        _confirmedOfficialProductNames
          ..clear()
          ..addAll(officialNamesByCode.values);
        _medicineLoadError = names.isEmpty ? '로그인 후 내 약을 불러올 수 있어요.' : null;
      });
      return;
    }

    setState(() {
      _isLoadingMedicines = true;
      _medicineLoadError = null;
    });
    try {
      final response = await _medicationApiClient.get(
        '/api/v1/users/${Uri.encodeComponent(userId)}/medicines',
      );
      final payload = Map<String, dynamic>.from(response as Map);
      final medicines = payload['medicines'];
      if (medicines is! List) {
        throw const FormatException('medicines must be a list');
      }
      // 성공한 약 데이터 Render 조회가 OCR 임시 목록을 대체하도록 한다.
      names.clear();
      officialMedicines.clear();
      ambiguousNames.clear();
      namesByCode.clear();
      officialNamesByCode.clear();
      namesByNormalizedName.clear();
      for (final medicine in medicines) {
        if (medicine is Map &&
            (medicine['status']?.toString() ?? 'active') == 'active') {
          final officialName = firstText([
            medicine['official_product_name'],
            medicine['product_name'],
            medicine['display_name'],
          ]);
          final ingredient = firstText([
            medicine['ingredient_name'],
            medicine['ingredient'],
          ]);
          addMedicine(
            officialName,
            medicine['medicine_code'],
            label: compactProductName(officialName, ingredient: ingredient),
          );
        }
      }
      for (final medicine in _temporaryMedicinesByCode.values) {
        addMedicine(medicine.itemName, medicine.itemSeq);
      }
      if (!mounted) return;
      setState(() {
        _medicines
          ..clear()
          ..addAll(names);
        _officialMedicinesByName
          ..clear()
          ..addAll(officialMedicines);
        _confirmedOfficialProductNames
          ..clear()
          ..addAll(officialNamesByCode.values);
        _medicineLoadError = names.isEmpty ? '등록된 처방/복용약이 없습니다.' : null;
      });
    } on ApiException {
      if (!mounted) return;
      setState(() {
        _medicines
          ..clear()
          ..addAll(names);
        _officialMedicinesByName
          ..clear()
          ..addAll(officialMedicines);
        _confirmedOfficialProductNames
          ..clear()
          ..addAll(officialNamesByCode.values);
        _medicineLoadError = _medicineLoadFailureMessage;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _medicines
          ..clear()
          ..addAll(names);
        _officialMedicinesByName
          ..clear()
          ..addAll(officialMedicines);
        _confirmedOfficialProductNames
          ..clear()
          ..addAll(officialNamesByCode.values);
        _medicineLoadError = '내 약을 불러오지 못했습니다.';
      });
    } finally {
      if (mounted) setState(() => _isLoadingMedicines = false);
    }
  }

  Future<void> _pickSubject() async {
    if (_isLoading) return;
    const options = <String>['일반 질문', '약 전체', '약 이름 선택'];
    final current = _selectedMedicines.isNotEmpty
        ? 2
        : (_isAllMedicinesSelected ? 1 : 0);
    final picked = await showSeniorWheel(
      context: context,
      title: '어떤 약을 물어볼까요?',
      options: options,
      selectedIndex: current,
      confirmLabel: '선택',
    );
    if (!mounted || picked == null) return;
    if (picked == 2) {
      await _pickMedicines();
      return;
    }
    final isAllMedicines = picked == 1;
    setState(() {
      _selectedMedicines.clear();
      _isAllMedicinesSelected = isAllMedicines;
      _pendingGeneralQuestion = null;
      _selectedKeyword = null;
    });
  }

  Future<void> _pickMedicines() async {
    final result = await SeniorSheet.show<_MedicineSelectionResult>(
      context: context,
      builder: (_) => _MedicineSelectionSheet(
        medicines: _medicines,
        selectedMedicines: _selectedMedicines,
      ),
    );
    if (!mounted || result == null) return;
    if (result.searchOther) {
      setState(() {
        _selectedMedicines
          ..clear()
          ..addAll(result.medicines);
      });
      await _enterOtherMedicine(addToSelection: true);
      return;
    }
    if (result.medicines.isEmpty) return;
    setState(() {
      _selectedMedicines
        ..clear()
        ..addAll(result.medicines);
      _isAllMedicinesSelected = false;
      _pendingGeneralQuestion = null;
      _selectedKeyword = null;
    });
  }

  Future<void> _askSuggestion(Map<String, String> suggestion) async {
    if (_isLoading) return;
    // 약을 아직 안 골랐으면 "제가 먹는 약"으로 물어본다. 되묻지 않는다.
    final medicine = _selectedMedicine?.trim();
    final subject = (medicine == null || medicine.isEmpty)
        ? '제가 먹는 약'
        : medicine;
    await _sendMessage(
      message: suggestion['prompt']!.replaceAll('{medicine}', subject),
      intent: suggestion['intent'],
    );
  }

  Future<void> _enterOtherMedicine({bool addToSelection = false}) async {
    final medicine = await SeniorSheet.show<_DrugSearchCandidate>(
      context: context,
      builder: (_) => _OtherMedicineDialog(apiClient: _apiClient),
    );
    if (!mounted || medicine == null) return;
    setState(() {
      if (!_medicines.contains(medicine.itemName)) {
        _medicines.add(medicine.itemName);
      }
      final code = medicine.itemSeq?.trim();
      if (code != null && code.isNotEmpty) {
        _temporaryMedicinesByCode[code] = medicine;
      }
      _officialMedicinesByName[medicine.itemName] = medicine;
      if (!addToSelection) _selectedMedicines.clear();
      if (!_selectedMedicines.contains(medicine.itemName)) {
        _selectedMedicines.add(medicine.itemName);
      }
      _isAllMedicinesSelected = false;
      _pendingGeneralQuestion = null;
      _selectedKeyword = null;
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage({
    String? message,
    String? displayMessage,
    String? intent,
  }) async {
    if (_isLoading) return;

    final text = (message ?? _chatController.text).trim();
    if (text.isEmpty) return;
    final pendingQuestion = _pendingGeneralQuestion;
    final isGeneralFreeInput =
        message == null &&
        _selectedMedicines.isEmpty &&
        !_isAllMedicinesSelected;
    final requestText = _hasMultipleMedicines && message == null
        ? '${_selectedRequestMedicineNames.join(', ')}에 대해 다음 질문에 답해 주세요: $text'
        : isGeneralFreeInput &&
              pendingQuestion != null &&
              _looksLikeMedicineIdentity(text)
        ? '$text에 대해 다음 질문에 답해 주세요: $pendingQuestion'
        : text;

    setState(() {
      _messages.add({'isMe': true, 'text': displayMessage ?? text});
      _isLoading = true;
      _selectedKeyword = null;
    });
    if (message == null) _chatController.clear();
    _scrollToBottom();

    try {
      final officialProductNames = _selectedMedicines.isNotEmpty
          ? _selectedMedicines
                .map((name) => _officialMedicinesByName[name]?.itemName)
                .whereType<String>()
                .toList(growable: false)
          : <String>{
              ..._confirmedOfficialProductNames,
              ..._temporaryMedicinesByCode.values.map(
                (medicine) => medicine.itemName,
              ),
            }.toList(growable: false);
      // TODO: 실제 AI 챗봇 API 엔드포인트로 변경 필요
      // 현재는 기존 약물 설명 API 구조를 임시로 챗봇 응답처럼 활용하도록 구성
      final body = <String, dynamic>{
        'user_id': MvpSession.userId,
        'message': requestText,
      };
      if (intent != null) body['intent'] = intent;
      final selectedOfficial = _selectedOfficialMedicine;
      if (selectedOfficial?.itemSeq != null) {
        body['selected_medicine'] = {
          'medicine_code': selectedOfficial!.itemSeq,
          'product_name': selectedOfficial.itemName,
        };
      }
      if (_hasMultipleMedicines) {
        body['selected_medicines'] = _selectedMedicines
            .map((name) {
              final official = _officialMedicinesByName[name];
              return {
                'medicine_code': official?.itemSeq ?? '',
                'product_name': official?.itemName ?? name,
              };
            })
            .toList(growable: false);
      }
      final temporaryMedicines = _isAllMedicinesSelected
          ? _temporaryMedicinesByCode.values
          : _temporaryMedicinesByCode.values.where(
              (medicine) => _selectedMedicines.contains(medicine.itemName),
            );
      if ((_isAllMedicinesSelected || _hasMultipleMedicines) &&
          temporaryMedicines.isNotEmpty) {
        body['temporary_medicines'] = temporaryMedicines
            .map(
              (medicine) => {
                'medicine_code': medicine.itemSeq,
                'product_name': medicine.itemName,
              },
            )
            .toList(growable: false);
      }
      final response = await _apiClient.post(
        '/api/v1/drug-explain/chat', // 가상의 챗봇 엔드포인트
        body: body,
      );

      final data = Map<String, dynamic>.from(response as Map);
      final reply = data['reply']?.toString() ?? '응답을 받아오지 못했습니다.';
      final asksForMedicine = reply.contains('물어볼 약을 선택하거나 제품명·성분명을 알려주세요');
      final generalCoffeeQuestion = _isGeneralCoffeeMedicineQuestion(text);

      if (!mounted) return;
      setState(() {
        if (isGeneralFreeInput) {
          _pendingGeneralQuestion = asksForMedicine
              ? (pendingQuestion ?? text)
              : generalCoffeeQuestion
              ? text
              : null;
        }
        _messages.add({
          'isMe': false,
          'text': _plainAiReply(reply),
          'officialProductNames': officialProductNames,
        });
      });
    } on ApiException {
      if (!mounted) return;
      setState(() {
        _messages.add({'isMe': false, 'text': _chatFailureMessage});
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _messages.add({'isMe': false, 'text': '통신 중 문제가 발생했습니다.\n다시 시도해주세요.'});
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
        _scrollToBottom();
      }
    }
  }

  bool _looksLikeMedicineIdentity(String text) {
    return RegExp(
      r'[0-9A-Za-z가-힣]{2,}(?:정|캡슐|연질|시럽|주사|액|패치|크림|산)(?=과|와|은|는|이|가|을|를|에|의|도|만|,|\s|$)',
    ).hasMatch(text.trim());
  }

  bool _isGeneralCoffeeMedicineQuestion(String text) {
    final normalized = text.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final mentionsCoffee =
        normalized.contains('커피') || normalized.contains('카페인');
    final mentionsMedicine =
        normalized.contains('약') ||
        normalized.contains('복용') ||
        normalized.contains('먹');
    return mentionsCoffee &&
        mentionsMedicine &&
        !_looksLikeMedicineIdentity(text);
  }

  Widget _buildKeywordBar(List<Map<String, String>> prompts) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: LayoutBuilder(
        builder: (context, constraints) => Scrollbar(
          child: SingleChildScrollView(
            key: ValueKey(
              _selectedMedicine ??
                  (_isAllMedicinesSelected ? 'all-medicines' : 'general'),
            ),
            scrollDirection: Axis.horizontal,
            child: Row(
              children: prompts.map((keyword) {
                final label = keyword['label']!;
                final selected = label == _selectedKeyword;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth - 8,
                    ),
                    child: ChoiceChip(
                      label: Text(label),
                      selected: selected,
                      onSelected: _isLoading
                          ? null
                          : (_) => _selectKeyword(keyword),
                      labelStyle: AppText.label(
                        size: 19,
                        color: selected ? Colors.white : AppColors.textBody,
                      ),
                      backgroundColor: AppColors.surface,
                      selectedColor: AppColors.point,
                      side: BorderSide(
                        color: selected
                            ? AppColors.point
                            : AppColors.strongLine,
                        width: 2,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 12,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 아직 아무것도 안 물어봤을 때만 예시 질문을 보여준다.
    final showSuggestions =
        _messages.length <= 1 && _selectedMedicines.length == 1;
    final subject = _selectedMedicine?.trim();
    final subjectLabel = _hasMultipleMedicines
        ? '${_selectedMedicines.first} 외 ${_selectedMedicines.length - 1}개'
        : subject?.isNotEmpty == true
        ? subject!
        : (_isAllMedicinesSelected ? '약 전체' : '일반 질문');

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            SeniorHeader(
              child: Row(
                children: [
                  const SeniorBackButton(),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '무엇이든 물어보세요',
                          style: AppText.screenTitle(size: 24),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '약 이야기를 쉬운 말로 알려드려요',
                          style: AppText.caption(size: 16.5),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 무엇에 대해 묻는지 늘 보이게 둔다. 고른 약은 질문에 함께 실린다.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
              child: SeniorCard(
                padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('물어볼 약', style: AppText.caption(size: 17.5)),
                          const SizedBox(height: 2),
                          Text(
                            subjectLabel,
                            style: AppText.cardTitle(size: 22),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Semantics(
                      button: true,
                      child: GestureDetector(
                        onTap: _pickSubject,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 12,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '바꾸기',
                                style: AppText.label(
                                  size: 19,
                                  color: AppColors.point,
                                ),
                              ),
                              const SizedBox(width: 4),
                              const SeniorChevron(color: AppColors.point),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  for (final message in _messages) ...[
                    _ChatBubble(
                      text: message['text'] as String,
                      isMe: message['isMe'] as bool,
                      officialProductNames:
                          (message['officialProductNames'] as List?)
                              ?.whereType<String>()
                              .toList(growable: false) ??
                          const [],
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_isLoadingMedicines) ...[
                    Text('내 약을 불러오는 중이에요…', style: AppText.caption(size: 18)),
                    const SizedBox(height: 12),
                  ] else if (_medicineLoadError != null) ...[
                    Text(
                      _medicineLoadError!,
                      style: AppText.caption(size: 16.5),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (showSuggestions) ...[
                    const SizedBox(height: 4),
                    Text('이렇게 물어보셔도 돼요', style: AppText.caption(size: 18.5)),
                    const SizedBox(height: 10),
                    for (final suggestion in _suggestions) ...[
                      SeniorCard(
                        onTap: () => _askSuggestion(suggestion),
                        borderColor: AppColors.border,
                        borderWidth: 2,
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                suggestion['label']!,
                                style: AppText.label(size: 21),
                              ),
                            ),
                            const SeniorChevron(),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                  if (_isLoading) ...[
                    const SizedBox(height: 4),
                    Text('답변을 작성하고 있어요', style: AppText.caption(size: 18)),
                  ],
                ],
              ),
            ),
            if (!_isLoadingMedicines &&
                (_isAllMedicinesSelected || _selectedMedicines.isNotEmpty))
              _buildKeywordBar(
                _isAllMedicinesSelected
                    ? _allMedicinePrompts
                    : _hasMultipleMedicines
                    ? _selectedMedicinePrompts
                    : _keywordPrompts,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 60),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(
                          color: AppColors.strongLine,
                          width: 2,
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: TextField(
                        controller: _chatController,
                        focusNode: _chatFocusNode,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _sendMessage(),
                        style: AppText.body(size: 20),
                        decoration: InputDecoration(
                          hintText: '여기에 물어보세요',
                          hintStyle: AppText.body(
                            size: 20,
                            color: AppColors.textTertiary,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Semantics(
                    button: true,
                    label: '질문 보내기',
                    child: GestureDetector(
                      onTap: _isLoading ? null : () => _sendMessage(),
                      child: Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          color: _isLoading
                              ? AppColors.inactive
                              : AppColors.point,
                          shape: BoxShape.circle,
                        ),
                        child: const ExcludeSemantics(
                          child: Icon(
                            Icons.send_rounded,
                            color: Colors.white,
                            size: 26,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MedicineSelectionResult {
  final List<String> medicines;
  final bool searchOther;

  const _MedicineSelectionResult({
    this.medicines = const [],
    this.searchOther = false,
  });
}

class _MedicineSelectionSheet extends StatefulWidget {
  final List<String> medicines;
  final List<String> selectedMedicines;

  const _MedicineSelectionSheet({
    required this.medicines,
    required this.selectedMedicines,
  });

  @override
  State<_MedicineSelectionSheet> createState() =>
      _MedicineSelectionSheetState();
}

class _MedicineSelectionSheetState extends State<_MedicineSelectionSheet> {
  late final Set<String> _selected = widget.selectedMedicines.toSet();

  @override
  Widget build(BuildContext context) {
    return SeniorSheet(
      title: '약 이름을 선택해 주세요',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '여러 약을 함께 확인하려면 두 개 이상 선택하세요.',
            style: AppText.body(size: 18, color: AppColors.textBody),
          ),
          const SizedBox(height: 10),
          for (final medicine in widget.medicines)
            Material(
              color: Colors.transparent,
              child: CheckboxListTile(
                key: ValueKey('medicine-selection-$medicine'),
                value: _selected.contains(medicine),
                onChanged: (checked) {
                  setState(() {
                    if (checked == true) {
                      _selected.add(medicine);
                    } else {
                      _selected.remove(medicine);
                    }
                  });
                },
                title: Text(medicine, style: AppText.label(size: 19)),
                activeColor: AppColors.point,
                checkColor: Colors.white,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          if (widget.medicines.isEmpty)
            Text(
              '목록에 약이 없습니다. 다른 약을 검색해 주세요.',
              style: AppText.caption(size: 17),
            ),
        ],
      ),
      actions: [
        SeniorButton(
          label: _selected.isEmpty ? '약을 선택해 주세요' : '${_selected.length}개 선택',
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(
                  context,
                ).pop(_MedicineSelectionResult(medicines: _selected.toList())),
        ),
        SeniorButton(
          label: '다른 약 검색하기',
          kind: SeniorButtonKind.secondary,
          minHeight: 60,
          fontSize: 19,
          onPressed: () => Navigator.of(context).pop(
            _MedicineSelectionResult(
              medicines: _selected.toList(),
              searchOther: true,
            ),
          ),
        ),
      ],
    );
  }
}

class _OtherMedicineDialog extends StatefulWidget {
  final ApiClient apiClient;

  const _OtherMedicineDialog({required this.apiClient});

  @override
  State<_OtherMedicineDialog> createState() => _OtherMedicineDialogState();
}

class _OtherMedicineDialogState extends State<_OtherMedicineDialog> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  List<_DrugSearchCandidate> _candidates = const [];
  bool _isSearching = false;
  String? _errorMessage;
  String? _inFlightQuery;
  String? _lastCompletedQuery;
  int _requestSequence = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _requestSequence++;
    _controller.dispose();
    super.dispose();
  }

  /// 자판의 "완료". 실패했던 검색어도 여기서 다시 물어본다.
  void _searchNow(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.length < 2) return;
    if (query == _inFlightQuery || query == _lastCompletedQuery) return;
    _search(query, ++_requestSequence);
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final sequence = ++_requestSequence;
    final query = value.trim();
    if (query.length < 2) {
      setState(() {
        _candidates = const [];
        _isSearching = false;
        _errorMessage = null;
      });
      return;
    }
    if (query == _inFlightQuery || query == _lastCompletedQuery) {
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 550),
      () => _search(query, sequence),
    );
  }

  Future<void> _search(String query, int sequence) async {
    if (query == _inFlightQuery) return;
    _inFlightQuery = query;
    setState(() {
      _isSearching = true;
      _errorMessage = null;
    });
    try {
      final response = await widget.apiClient.get(
        '/api/v1/drugs/search?q=${Uri.encodeQueryComponent(query)}',
      );
      if (!mounted ||
          sequence != _requestSequence ||
          _controller.text.trim() != query) {
        return;
      }
      final data = Map<String, dynamic>.from(response as Map);
      final rawItems = data['items'];
      final candidates = rawItems is List
          ? rawItems
                .whereType<Map>()
                .map(
                  (item) => _DrugSearchCandidate.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .where((item) => item.itemName.isNotEmpty)
                .toList()
          : <_DrugSearchCandidate>[];
      setState(() {
        _candidates = candidates;
        _lastCompletedQuery = query;
      });
    } on ApiException catch (error) {
      if (!mounted || sequence != _requestSequence) return;
      setState(() {
        _candidates = const [];
        _errorMessage = error.statusCode == null
            ? '네트워크 연결을 확인한 후 다시 시도해주세요.'
            : '의약품 정보를 불러오지 못했습니다. 다시 시도해주세요.';
      });
    } catch (_) {
      if (!mounted || sequence != _requestSequence) return;
      setState(() {
        _candidates = const [];
        _errorMessage = '의약품 정보를 불러오지 못했습니다. 다시 시도해주세요.';
      });
    } finally {
      if (_inFlightQuery == query) {
        _inFlightQuery = null;
      }
      if (mounted && sequence == _requestSequence) {
        setState(() => _isSearching = false);
      }
    }
  }

  void _select(_DrugSearchCandidate candidate) {
    Navigator.of(context).pop(candidate);
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final availableHeight =
        mediaQuery.size.height - mediaQuery.viewInsets.bottom;
    final maxContentHeight = (availableHeight - 200)
        .clamp(120.0, 368.0)
        .toDouble();

    return SeniorSheet(
      title: '다른 약 검색하기',
      body: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxContentHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SeniorField(
              key: const Key('otherMedicineSearchField'),
              controller: _controller,
              hint: '약 이름을 적어 주세요',
              textInputAction: TextInputAction.search,
              onChanged: _onQueryChanged,
              onSubmitted: _searchNow,
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: _buildSearchContent(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        SeniorButton(
          label: '취소',
          kind: SeniorButtonKind.neutral,
          minHeight: 62,
          fontSize: 20,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  Widget _buildSearchContent() {
    if (_controller.text.trim().length < 2) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Text('약 이름을 2글자 이상 입력해주세요.'),
      );
    }
    if (_isSearching) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
      );
    }
    if (_errorMessage != null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(_errorMessage!, key: const Key('drugSearchError')),
      );
    }
    if (_candidates.isEmpty) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Text('검색된 공식 의약품이 없습니다.'),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      itemCount: _candidates.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final candidate = _candidates[index];
        // 시트 안에서는 ListTile이 제 배경을 못 칠한다. 줄을 직접 그린다.
        return GestureDetector(
          key: ValueKey(
            'drugCandidate:${candidate.itemSeq ?? candidate.itemName}',
          ),
          behavior: HitTestBehavior.opaque,
          onTap: () => _select(candidate),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        candidate.itemName,
                        style: AppText.cardTitle(size: 19),
                      ),
                      if (candidate.manufacturer != null)
                        Text(
                          candidate.manufacturer!,
                          style: AppText.caption(size: 16),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                const SeniorChevron(),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DrugSearchCandidate {
  final String itemName;
  final String? manufacturer;
  final String? itemSeq;

  const _DrugSearchCandidate({
    required this.itemName,
    this.manufacturer,
    this.itemSeq,
  });

  factory _DrugSearchCandidate.fromJson(Map<String, dynamic> json) {
    String? optionalText(dynamic value) {
      final text = value?.toString().trim();
      return text == null || text.isEmpty ? null : text;
    }

    return _DrugSearchCandidate(
      itemName: json['item_name']?.toString().trim() ?? '',
      manufacturer: optionalText(json['manufacturer']),
      itemSeq: optionalText(json['item_seq']),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final bool isMe;
  final String text;
  final List<String> officialProductNames;

  const _ChatBubble({
    required this.isMe,
    required this.text,
    this.officialProductNames = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment: isMe
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              decoration: BoxDecoration(
                color: isMe ? kPrimary : Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isMe ? 16 : 4),
                  bottomRight: Radius.circular(isMe ? 4 : 16),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Text.rich(
                TextSpan(
                  children: _officialProductNameSpans(
                    text,
                    isMe ? const [] : officialProductNames,
                    AppText.body(
                      size: 20,
                      color: isMe ? Colors.white : AppColors.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (isMe) const SizedBox(width: 44),
        ],
      ),
    );
  }
}

List<TextSpan> _officialProductNameSpans(
  String text,
  List<String> officialProductNames,
  TextStyle baseStyle,
) {
  final names =
      officialProductNames
          .map((name) => name.trim())
          .where((name) => name.isNotEmpty)
          .toSet()
          .toList()
        ..sort((left, right) => right.length.compareTo(left.length));
  if (names.isEmpty) return [TextSpan(text: text, style: baseStyle)];

  final matches = <({int start, int end})>[];
  var cursor = 0;
  while (cursor < text.length) {
    ({int start, int end})? next;
    for (final name in names) {
      var start = text.indexOf(name, cursor);
      while (start >= 0 &&
          !_hasOfficialProductNameBoundary(text, start, name)) {
        start = text.indexOf(name, start + 1);
      }
      if (start < 0) continue;
      final candidate = (start: start, end: start + name.length);
      if (next == null ||
          candidate.start < next.start ||
          (candidate.start == next.start && candidate.end > next.end)) {
        next = candidate;
      }
    }
    if (next == null) break;
    matches.add(next);
    cursor = next.end;
  }
  if (matches.isEmpty) return [TextSpan(text: text, style: baseStyle)];

  final spans = <TextSpan>[];
  cursor = 0;
  for (final match in matches) {
    if (match.start > cursor) {
      spans.add(
        TextSpan(text: text.substring(cursor, match.start), style: baseStyle),
      );
    }
    spans.add(
      TextSpan(
        text: text.substring(match.start, match.end),
        style: baseStyle.copyWith(
          color: AppColors.detailEmphasis,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor), style: baseStyle));
  }
  return spans;
}

bool _hasOfficialProductNameBoundary(String text, int start, String name) {
  final word = RegExp(r'[A-Za-z0-9가-힣_]');
  if (start > 0 && word.hasMatch(text[start - 1])) return false;
  final end = start + name.length;
  if (end >= text.length || !word.hasMatch(text[end])) return true;

  const particles = [
    '에게',
    '께서',
    '처럼',
    '보다',
    '에서',
    '으로',
    '은',
    '는',
    '이',
    '가',
    '을',
    '를',
    '과',
    '와',
    '의',
    '에',
    '로',
    '도',
    '만',
  ];
  for (final particle in particles) {
    if (!text.startsWith(particle, end)) continue;
    final afterParticle = end + particle.length;
    if (afterParticle >= text.length || !word.hasMatch(text[afterParticle])) {
      return true;
    }
  }
  return false;
}

const _medicineLoadFailureMessage = '지금은 등록한 약을 불러오지 못했어요.\n잠시 후 다시 시도해 주세요.';

const _chatFailureMessage =
    '지금은 답변을 불러오지 못했어요.\n'
    '잠시 후 다시 시도해 주세요.\n'
    '약의 사용 방법을 임의로 바꾸지는 마세요.';

String _plainAiReply(String value) {
  var text = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  text = text.replaceAll(
    RegExp(r'^[ \t]*```(?:[A-Za-z][A-Za-z0-9_-]*)?[ \t]*$', multiLine: true),
    '',
  );
  text = text.replaceAll(
    RegExp(r'^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$', multiLine: true),
    '',
  );
  text = text.replaceAll(
    RegExp(r'^[ \t]{0,3}#{1,6}[ \t]+', multiLine: true),
    '',
  );
  text = text.replaceAll(RegExp(r'^[ \t]{0,3}>+[ \t]?', multiLine: true), '');
  text = text.replaceAll(
    RegExp(r'^[ \t]{0,3}\d+[.)][ \t]+', multiLine: true),
    '• ',
  );
  text = text.replaceAll(
    RegExp(r'^[ \t]{0,3}[-*+][ \t]+', multiLine: true),
    '• ',
  );
  text = text.replaceAllMapped(
    RegExp(r'\*\*([^*\n]+)\*\*'),
    (match) => match.group(1)!,
  );
  text = text.replaceAllMapped(
    RegExp(r'__([^\n]+?)__'),
    (match) => match.group(1)!,
  );
  text = text.replaceAllMapped(
    RegExp(r'(?<![A-Za-z0-9가-힣_*])\*([^*\s\n](?:[^*\n]*?[^*\s\n])?)\*(?!\*)'),
    (match) => match.group(1)!,
  );
  text = text.replaceAllMapped(
    RegExp(r'(?<![A-Za-z0-9가-힣_])_([^_\s\n](?:[^_\n]*?[^_\s\n])?)_(?!_)'),
    (match) => match.group(1)!,
  );
  text = text.replaceAllMapped(
    RegExp(r'\[([^\]\n]+)\]\([^\s)]+(?:\s+"[^"]*")?\)'),
    (match) => match.group(1)!,
  );
  text = text.replaceAll('`', '');
  text = text
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t]{3,}'), ' ').trimRight())
      .join('\n');
  return text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}
