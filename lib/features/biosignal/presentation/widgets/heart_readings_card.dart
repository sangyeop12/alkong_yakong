import 'package:flutter/material.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_card.dart';
import '../../../medication/domain/medication_models.dart';
import '../../domain/heart_data.dart';

/// Stored measurements are listed once; comparison pairs are not added to them.
class HeartReadingsCard extends StatelessWidget {
  final List<HeartReading> readings;
  final bool hasComparison;
  const HeartReadingsCard({
    super.key,
    required this.readings,
    required this.hasComparison,
  });

  @override
  Widget build(BuildContext context) => SeniorCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('저장된 심박 기록', style: AppText.cardTitle(size: 21)),
        for (final reading in readings) ...[
          const SizedBox(height: 12),
          Text(
            '${reading.measuredAt.toLocal().month}월 ${reading.measuredAt.toLocal().day}일 '
            '${DoseSlot.absoluteTime(reading.measuredAt.toLocal())} · ${reading.bpm}회/분',
            style: AppText.body(size: 18),
          ),
          const SizedBox(height: 3),
          Text(
            reading.measurementContext.label,
            style: AppText.caption(size: 16),
          ),
        ],
      ],
    ),
  );
}
