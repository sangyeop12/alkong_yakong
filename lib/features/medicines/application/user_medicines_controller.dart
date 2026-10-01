import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_config.dart';
import '../../../core/session/mvp_session.dart';
import '../domain/display_policy.dart';
import '../domain/user_medicine_models.dart';

/// 그 어르신의 약 보관 목록. 보호자가 돌보는 분 관리에서 본다.
///
/// 본인 목록([userMedicinesProvider])과 같은 응답을 쓰되, 누구 것인지만
/// 다르다. 보호자 화면에서 본인 목록을 그대로 쓰면 남의 약을 자기 약으로
/// 읽는다.
final patientMedicinesProvider =
    FutureProvider.family<List<UserMedicine>, String>((ref, patientId) async {
      final id = patientId.trim();
      if (id.isEmpty) return const [];
      final response = await ApiClient(
        baseUrl: ApiConfig.localFeatureBaseUrl,
      ).get('/api/v1/users/${Uri.encodeComponent(id)}/medicines');
      if (response is! Map) throw const ApiException('약 목록을 읽을 수 없습니다.');
      final raw = response['medicines'];
      if (raw is! List) throw const ApiException('약 목록을 읽을 수 없습니다.');
      return [
        for (final item in raw)
          if (item is Map)
            UserMedicine.fromJson(Map<String, dynamic>.from(item)),
      ].where((med) => !isMockDrugInfoName(med.displayName)).toList();
    });

final userMedicinesProvider =
    AsyncNotifierProvider<UserMedicinesController, List<UserMedicine>>(
      UserMedicinesController.new,
    );

/// 활성 내 약 목록·상세를 서버에서 불러온다.
class UserMedicinesController extends AsyncNotifier<List<UserMedicine>> {
  final _api = ApiClient(baseUrl: ApiConfig.localFeatureBaseUrl);

  @override
  Future<List<UserMedicine>> build() async {
    return _loadMedicines();
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_loadMedicines);
  }

  Future<UserMedicine> loadDetail(String medicineCode) async {
    final code = medicineCode.trim();
    if (code.isEmpty) {
      throw const ApiException('약 코드가 없습니다.');
    }
    final userId = Uri.encodeComponent(MvpSession.userId);
    final response = await _api.get(
      '/api/v1/users/$userId/medicines/${Uri.encodeComponent(code)}',
    );
    if (response is! Map) {
      throw const ApiException('약 정보를 읽을 수 없습니다.');
    }
    final med = response['medicine'];
    if (med is! Map) {
      throw const ApiException('약 정보를 읽을 수 없습니다.');
    }
    final data = Map<String, dynamic>.from(med);
    final explanation = response['explanation'];
    if (explanation is Map) {
      data['short_explanation'] =
          explanation['short_explanation'] ?? data['short_explanation'];
      data['ingredient_explanation'] = explanation['ingredient_explanation'];
      data['ingredient_highlight'] = explanation['ingredient_highlight'];
      data['approved_use_summary'] = explanation['approved_use_summary'];
      data['approved_uses'] = explanation['approved_uses'];
      data['all_approved_uses'] = explanation['all_approved_uses'];
      data['treatment_uses'] = explanation['treatment_uses'];
      data['detail_review_status'] = explanation['review_status'];
      data['detail_status'] = explanation['status'];
    }
    final patientDosage = response['patient_dosage'];
    if (patientDosage is Map) {
      data['amount'] = patientDosage['amount'] ?? data['amount'];
      data['dosage'] = patientDosage['dosage'] ?? data['dosage'];
      data['frequency_per_day'] =
          patientDosage['frequency_per_day'] ?? data['frequency_per_day'];
      data['administration_times'] =
          patientDosage['administration_times'] ?? data['administration_times'];
    }
    final officialUsage = response['official_usage'];
    if (officialUsage is Map) {
      data['official_usage'] = officialUsage['text'];
      data['official_usage_notice'] = officialUsage['notice'];
    }
    final safety = response['safety'];
    if (safety is Map) {
      data['key_cautions'] = safety['key_cautions'] ?? data['key_cautions'];
      data['ask_doctor_when'] = safety['ask_doctor_when'];
      data['possible_side_effects'] = safety['possible_side_effects'];
      data['interaction_status'] =
          safety['interaction_status'] ?? data['interaction_status'];
      data['interaction_summary'] =
          safety['interaction_summary'] ?? data['interaction_summary'];
      data['interaction_risk_level'] =
          safety['interaction_risk_level'] ?? data['interaction_risk_level'];
      data['interaction_conflict_names'] =
          safety['interaction_conflict_names'] ??
          data['interaction_conflict_names'];
      data['interaction_risk_factor'] =
          safety['interaction_risk_factor'] ?? data['interaction_risk_factor'];
      data['interaction_pair_label'] =
          safety['interaction_pair_label'] ?? data['interaction_pair_label'];
    }
    final source = response['source'];
    if (source is Map) {
      data['detail_source_name'] = source['name'];
      data['detail_source_verified'] = source['source_verified'];
      data['detail_content_generated_by'] = source['content_generated_by'];
      data['detail_served_from'] = source['served_from'];
      data['detail_content_version'] = source['content_version'];
    }
    return UserMedicine.fromJson(data);
  }

  Future<List<UserMedicine>> _loadMedicines() async {
    final userId = Uri.encodeComponent(MvpSession.userId);
    final response = await _api.get('/api/v1/users/$userId/medicines');
    if (response is! Map) throw const ApiException('내 약 목록을 읽을 수 없습니다.');
    final raw = response['medicines'];
    if (raw is! List) throw const ApiException('내 약 목록을 읽을 수 없습니다.');
    return [
      for (final item in raw)
        if (item is Map) UserMedicine.fromJson(Map<String, dynamic>.from(item)),
    ].where((med) => !isMockDrugInfoName(med.displayName)).toList();
  }
}
