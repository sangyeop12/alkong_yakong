import '../../medication/domain/medication_models.dart';

/// Convert the instant once, then use the same local day and clock for display.
String heartSavedTimeLabel(
  DateTime instant, {
  DateTime? now,
  DateTime Function(DateTime)? localize,
}) {
  final convert = localize ?? (DateTime value) => value.toLocal();
  final local = convert(instant);
  final today = convert(now ?? DateTime.now());
  final date =
      local.year == today.year &&
          local.month == today.month &&
          local.day == today.day
      ? '오늘'
      : '${local.year}년 ${local.month}월 ${local.day}일';
  return '$date ${DoseSlot.absoluteTime(local)}';
}
