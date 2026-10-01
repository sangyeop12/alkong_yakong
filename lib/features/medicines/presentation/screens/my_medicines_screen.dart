import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/recovery_view.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../application/user_medicines_controller.dart';
import '../../domain/user_medicine_models.dart';

/// 내 약 목록 — 활성 약 종류당 1행 (서버 `/medicines`).
class MyMedicinesScreen extends ConsumerWidget {
  const MyMedicinesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final medicines = ref.watch(userMedicinesProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          SeniorBackHeader(title: '내 약 목록', onBack: () => context.pop()),
          Expanded(
            child: medicines.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => RecoveryView(
                title: '약 목록을\n불러오지 못했어요',
                reassurance: '인터넷이나 서버가 잠깐 끊겼을 수 있어요. ',
                reassuranceEmphasis: '고장이 아니니 걱정하지 마세요.',
                steps: const ['잠시 후 다시 시도해 보세요', '와이파이나 데이터 연결을 확인해 보세요'],
                actionLabel: '다시 불러오기',
                onAction: () =>
                    ref.read(userMedicinesProvider.notifier).refresh(),
                stillWorksTitle: '지금도 할 수 있는 것',
                stillWorksBody: '오늘 홈에서 복약 기록과 처방전 등록은 그대로 쓸 수 있어요.',
              ),
              data: (items) => _MedicineList(items: items),
            ),
          ),
        ],
      ),
    );
  }
}

class _MedicineList extends StatelessWidget {
  final List<UserMedicine> items;

  const _MedicineList({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SeniorCard(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Icon(
                    TablerIcons.pill,
                    size: 42,
                    color: AppColors.point,
                  ),
                  const SizedBox(height: 14),
                  Text('등록된 약이 없어요', style: AppText.cardTitle(size: 22)),
                  const SizedBox(height: 8),
                  Text(
                    '처방전 사진을 찍으면 약을 확인한 뒤 등록할 수 있어요.',
                    textAlign: TextAlign.center,
                    style: AppText.body(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SeniorButton(
              label: '처방전 등록하기',
              onPressed: () => context.push('/prescription'),
            ),
          ],
        ),
      );
    }

    final active = items.where((item) => item.status == 'active').toList();
    final past = items.where((item) => item.status != 'active').toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        Text(
          '약을 누르면 설명이 나와요',
          style: AppText.body(size: 19, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 14),
        for (final med in active) ...[
          _MedicineCard(medicine: med),
          const SizedBox(height: 10),
        ],
        // 지금 안 드시는 약은 줄 하나로 접어 둔다. 목록을 보는 이유는
        // 대부분 "지금 먹는 약"이기 때문이다.
        if (past.isNotEmpty) ...[
          const SizedBox(height: 2),
          _PastMedicines(medicines: past),
        ],
        const SizedBox(height: 18),
        SeniorButton(
          label: '새 처방전 넣기',
          kind: SeniorButtonKind.secondary,
          minHeight: 66,
          onPressed: () => context.push('/prescription'),
        ),
      ],
    );
  }
}

class _MedicineCard extends StatelessWidget {
  final UserMedicine medicine;

  /// 지금 안 드시는 약. 칸 색은 그대로 두고 왼쪽 회색 띠와 회색 글씨로
  /// 지금 드시는 약과 갈라 둔다.
  final bool past;

  const _MedicineCard({required this.medicine, this.past = false});

  @override
  Widget build(BuildContext context) {
    if (past) {
      return _StackedCard(child: _body(context));
    }
    return _body(context);
  }

  Widget _body(BuildContext context) {
    return SeniorCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      onTap: () => context.push('/medicines/${medicine.medicineCode}'),
      child: Row(
        children: [
          // 홈 카드와 같은 생김새여야 같은 약으로 읽힌다.
          const PillPhoto(size: 56),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              medicine.displayName,
              style: AppText.cardTitle(
                size: 20,
                color: past ? AppColors.textTertiary : AppColors.textPrimary,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          const SeniorChevron(),
        ],
      ),
    );
  }
}

/// 지금은 안 드시는 약. 줄을 누르면 그 자리에서 펴진다.
class _PastMedicines extends StatefulWidget {
  final List<UserMedicine> medicines;

  const _PastMedicines({required this.medicines});

  @override
  State<_PastMedicines> createState() => _PastMedicinesState();
}

class _PastMedicinesState extends State<_PastMedicines> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StackedCard(
          child: SeniorCard(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: SeniorListRow(
              label: '이전에 등록한 약',
              labelColor: AppColors.textTertiary,
              value: '${widget.medicines.length}가지',
              trailing: const SeniorChevron(),
              onTap: () => setState(() => _open = !_open),
            ),
          ),
        ),
        if (_open)
          for (final med in widget.medicines) ...[
            const SizedBox(height: 10),
            _MedicineCard(medicine: med, past: true),
          ],
      ],
    );
  }
}

/// 카드 한 장이 뒤에 더 깔린 모양.
///
/// 지금 드시는 약과 같은 흰 카드를 쓰되, 뒤에 회색 카드가 왼쪽으로 조금
/// 삐져나오게 둔다. "이 아래에 지난 약이 더 있다"를 색이 아니라 모양으로 말한다.
class _StackedCard extends StatelessWidget {
  final Widget child;

  const _StackedCard({required this.child});

  /// 뒤 카드가 왼쪽으로 보이는 만큼.
  static const double _peek = 6;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 카드와 똑같은 크기·모서리로 한 장을 왼쪽으로 밀어 깐다.
        // 그래야 삐져나온 회색이 위아래 모서리까지 카드를 따라 휘어진다.
        Positioned(
          left: 0,
          right: _peek,
          top: 0,
          bottom: 0,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.chevron,
              borderRadius: BorderRadius.circular(22),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: _peek),
          child: child,
        ),
      ],
    );
  }
}

/// 복용 시간대를 "아침 · 저녁" 한 줄로 만든다.
///
/// 서버가 한글로도 영문으로도 보낼 수 있어 둘 다 받는다.
/// 알 수 없는 값만 들어 있으면 null — **배지를 만들지 않는다.**
String? slotBadgeFor(List<String> times) {
  const order = ['아침', '점심', '저녁', '자기 전'];
  const alias = {
    'morning': '아침',
    'lunch': '점심',
    'noon': '점심',
    'afternoon': '점심',
    'evening': '저녁',
    'dinner': '저녁',
    'night': '자기 전',
    'bedtime': '자기 전',
  };

  final found = <String>{};
  for (final raw in times) {
    final text = raw.trim();
    if (text.isEmpty) continue;
    final lower = text.toLowerCase();
    for (final entry in alias.entries) {
      if (lower.contains(entry.key)) found.add(entry.value);
    }
    for (final label in order) {
      if (text.contains(label)) found.add(label);
    }
  }
  if (found.isEmpty) return null;
  return order.where(found.contains).join(' · ');
}
