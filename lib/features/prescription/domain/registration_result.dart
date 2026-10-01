/// Registration consumers must not interpret an absent/malformed DUR as zero risk.
bool registrationDurComplete(Map<String, dynamic>? result) {
  if (result == null ||
      result['analysis_complete'] != true ||
      result['incomplete'] == true ||
      result['has_risk'] is! bool ||
      !{'SAFE', 'RISK_FOUND'}.contains(result['assessment_status'])) {
    return false;
  }
  final matches = result['matches'];
  return matches is List &&
      (result['has_risk'] == matches.isNotEmpty) &&
      (result['assessment_status'] ==
          (matches.isEmpty ? 'SAFE' : 'RISK_FOUND')) &&
      matches.every(
        (m) =>
            m is Map && m['type'] is String && (m['type'] as String).isNotEmpty,
      );
}

Map<String, dynamic> registrationDurResult(dynamic value) {
  final result = value is Map
      ? Map<String, dynamic>.from(value)
      : <String, dynamic>{};
  if (registrationDurComplete(result)) return result;
  return {
    ...result,
    'analysis_complete': false,
    'incomplete': true,
    'assessment_status': 'INCOMPLETE',
    'has_risk': null,
  };
}
