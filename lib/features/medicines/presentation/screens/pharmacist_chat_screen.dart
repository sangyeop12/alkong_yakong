import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../../core/widgets/senior_sheet.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../profile/application/current_user_controller.dart';
import '../../application/user_medicines_controller.dart';
import '../../domain/drug_info.dart';

/// 22 / 23 · AI 약사 상담.
///
/// 답변 아래에는 **항상** 면책 문장이 붙는다.
/// 약을 바꾸거나 끊는 결정은 앱이 하지 않는다.
class PharmacistChatScreen extends ConsumerStatefulWidget {
  /// 인사말에 쓸 이름. 없으면 로그인한 사람의 이름을 쓴다.
  final String? userName;

  const PharmacistChatScreen({super.key, this.userName});

  @override
  ConsumerState<PharmacistChatScreen> createState() =>
      _PharmacistChatScreenState();
}

class _PharmacistChatScreenState extends ConsumerState<PharmacistChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  late final List<_Message> _messages = [_Message.bot(_greeting())];

  /// 어떤 약에 대해 묻는지. null이면 드시는 약 전체다.
  String? _subject;

  /// 물어볼 약을 고른다. 약을 고르면 질문 앞에 그 이름이 붙는다.
  Future<void> _pickSubject() async {
    final medicines = ref.read(userMedicinesProvider).valueOrNull ?? const [];
    final names = [
      for (final medicine in medicines)
        if (medicine.displayName.trim().isNotEmpty) medicine.displayName.trim(),
    ];
    final picked = await SeniorSheet.show<String>(
      context: context,
      builder: (sheetContext) => SeniorSheet(
        title: '어떤 약을 물어볼까요?',
        body: SeniorSheetBody.plain('고른 약에 맞춰 답해 드려요.'),
        actions: [
          SeniorButton(
            label: '약 전체',
            kind: SeniorButtonKind.secondary,
            minHeight: 62,
            fontSize: 20,
            onPressed: () => Navigator.of(sheetContext).pop('전체'),
          ),
          for (final name in names)
            SeniorButton(
              label: name,
              kind: SeniorButtonKind.secondary,
              minHeight: 62,
              fontSize: 20,
              onPressed: () => Navigator.of(sheetContext).pop(name),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _subject = picked == '전체' ? null : picked);
  }

  String _greeting() {
    final String signedIn = ref.read(currentUserNameProvider);
    final name = (widget.userName ?? signedIn).trim();
    const ask = '약에 대해 궁금한 걸 편하게 물어보세요.';
    return name.isEmpty ? '안녕하세요. $ask' : '$name 님, 안녕하세요. $ask';
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _ask(String rawQuestion) {
    final subject = _subject;
    final question = subject == null ? rawQuestion : '$subject · $rawQuestion';
    final match = PharmacistAnswer.suggested
        .where((a) => a.question == rawQuestion)
        .firstOrNull;
    setState(() {
      _messages.add(_Message.user(question));
      _messages.add(
        _Message.bot(
          match?.answer ??
              '그 부분은 약사님께 여쭤보시는 게 정확해요. '
                  '지금 드시는 약과 함께 여쭤보시면 좋습니다.',
          withDisclaimer: true,
        ),
      );
    });
    _input.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 아직 아무것도 안 물어봤을 때만 추천 질문을 보여준다.
    final showSuggestions = _messages.length == 1;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
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
                      Text('무엇이든 물어보세요', style: AppText.screenTitle(size: 24)),
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
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              children: [
                SeniorCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 4,
                  ),
                  child: SeniorListRow(
                    label: '물어볼 약',
                    subtitle: _subject ?? '약 전체',
                    value: '바꾸기',
                    valueColor: AppColors.point,
                    trailing: const SeniorChevron(),
                    onTap: _pickSubject,
                  ),
                ),
                const SizedBox(height: 14),
                for (final message in _messages) ...[
                  _Bubble(message: message),
                  const SizedBox(height: 12),
                ],
                if (showSuggestions) ...[
                  const SizedBox(height: 4),
                  Text('이렇게 물어보셔도 돼요', style: AppText.caption(size: 17)),
                  const SizedBox(height: 10),
                  for (final item in PharmacistAnswer.suggested) ...[
                    _SuggestionCard(
                      question: item.question,
                      onTap: () => _ask(item.question),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ],
            ),
          ),
          _InputBar(
            controller: _input,
            onSend: () {
              final text = _input.text.trim();
              if (text.isNotEmpty) _ask(text);
            },
          ),
        ],
      ),
    );
  }
}

class _Message {
  final String text;
  final bool fromBot;
  final bool withDisclaimer;

  const _Message.bot(this.text, {this.withDisclaimer = false}) : fromBot = true;

  const _Message.user(this.text) : fromBot = false, withDisclaimer = false;
}

class _Bubble extends StatelessWidget {
  final _Message message;
  const _Bubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final bot = message.fromBot;
    return Align(
      alignment: bot ? Alignment.centerLeft : Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.88,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          decoration: BoxDecoration(
            color: bot ? AppColors.surface : AppColors.point,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(22),
              topRight: const Radius.circular(22),
              bottomLeft: Radius.circular(bot ? 8 : 22),
              bottomRight: Radius.circular(bot ? 22 : 8),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (bot) ...[
                Text(
                  '알콩이',
                  style: AppText.cardTitle(size: 16, color: AppColors.point),
                ),
                const SizedBox(height: 6),
              ],
              Text(
                message.text,
                style: AppText.body(
                  size: 20,
                  color: bot ? AppColors.textBody : Colors.white,
                  weight: FontWeight.w700,
                ),
              ),
              if (message.withDisclaimer) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 15,
                    vertical: 13,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.dangerBgSoft,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    PharmacistAnswer.disclaimer,
                    style: AppText.label(size: 17, color: AppColors.danger),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  final String question;
  final VoidCallback onTap;

  const _SuggestionCard({required this.question, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.border, width: 2),
          ),
          child: Text(
            question,
            style: AppText.label(size: 19, color: AppColors.textPrimary),
          ),
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;

  const _InputBar({required this.controller, required this.onSend});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.sunken,
        border: Border(top: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(minHeight: 62),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppColors.border, width: 2),
                  ),
                  child: Center(
                    child: TextField(
                      controller: controller,
                      onSubmitted: (_) => onSend(),
                      style: AppText.body(
                        size: 19,
                        color: AppColors.textPrimary,
                      ),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                        hintText: '여기에 물어보세요',
                        hintStyle: AppText.body(
                          size: 19,
                          color: AppColors.chevron,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Semantics(
                button: true,
                label: '보내기',
                child: GestureDetector(
                  onTap: onSend,
                  child: Container(
                    width: 62,
                    height: 62,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.point,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const ExcludeSemantics(
                      child: Icon(
                        TablerIcons.send,
                        size: 28,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
