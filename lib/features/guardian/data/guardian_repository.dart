import '../../../core/network/api_client.dart';
import '../../../core/session/mvp_session.dart';
import '../../dashboard/presentation/screens/patient_data.dart';

/// 초대를 보낸 결과.
///
/// 보냈는지 못 보냈는지를 분명히 나눈다. 실패했는데 목록에 올려 두면
/// 어르신은 초대를 받은 적이 없는데 보호자는 기다리게 된다.
class InviteResult {
  final PendingInvite? invite;
  final String? error;

  const InviteResult.sent(PendingInvite this.invite) : error = null;
  const InviteResult.failed(String this.error) : invite = null;

  bool get isSent => invite != null;
}

/// 어르신 쪽에서 보는 보호자 한 사람.
class GuardianContact {
  final String id;
  final String name;
  final String? relation;
  final String? phone;

  /// 'ACCEPTED' · 'PENDING'.
  final String status;

  /// 누가 먼저 연결을 청했는지. 'PATIENT' · 'GUARDIAN'.
  final String requestedBy;

  const GuardianContact({
    required this.id,
    required this.name,
    this.relation,
    this.phone,
    this.status = 'ACCEPTED',
    this.requestedBy = 'PATIENT',
  });

  factory GuardianContact.fromJson(Map<String, dynamic> json) {
    String? text(dynamic value) {
      final trimmed = value?.toString().trim() ?? '';
      return trimmed.isEmpty ? null : trimmed;
    }

    return GuardianContact(
      id: text(json['id']) ?? '',
      name: text(json['guardian_name']) ?? '',
      relation: text(json['relationship']),
      phone: text(json['phone']),
      status: (text(json['status']) ?? 'ACCEPTED').toUpperCase(),
      requestedBy: (text(json['requested_by']) ?? 'PATIENT').toUpperCase(),
    );
  }

  /// "딸 김지안".
  String get label => relation == null ? name : '$relation $name';

  bool get isPending => status == 'PENDING';

  /// 보호자가 먼저 요청해서 어르신의 대답을 기다리는 중인지.
  bool get awaitsMyAnswer => isPending && requestedBy == 'GUARDIAN';
}

/// 보호자 연결 — 어르신의 가족 초대, 보호자의 연결 요청, 수락·해제, 현황.
class GuardianRepository {
  GuardianRepository({ApiClient? apiClient})
    : _apiClient = apiClient ?? ApiClient();

  final ApiClient _apiClient;

  /// 이 어르신에게 등록된 보호자들(수락 대기 포함). 먼저 등록한 순서.
  Future<List<GuardianContact>> fetchAll({String? userId}) async {
    final id = (userId ?? MvpSession.userId).trim();
    if (id.isEmpty) return const [];
    final response = await _apiClient.get(
      '/api/v1/guardians/users/${Uri.encodeComponent(id)}',
    );
    if (response is! List) return const [];
    return [
      for (final row in response)
        if (row is Map)
          GuardianContact.fromJson(Map<String, dynamic>.from(row)),
    ].where((contact) => contact.name.isNotEmpty).toList();
  }

  /// 보호자가 돌보는 어르신들의 오늘 현황. 못 읽으면 예외를 그대로 올린다.
  Future<CareOverview> fetchCareOverview({String? guardianUserId}) async {
    final id = (guardianUserId ?? MvpSession.userId).trim();
    if (id.isEmpty) return const CareOverview();
    final response = await _apiClient.get(
      '/api/v1/guardians/accounts/${Uri.encodeComponent(id)}/patients',
    );
    if (response is! Map) {
      throw const ApiException('돌보는 분 목록을 받지 못했어요.');
    }
    final patients = response['patients'];
    final pending = response['pending'];
    return CareOverview(
      patients: [
        if (patients is List)
          for (final row in patients)
            if (row is Map)
              CarePatient.fromJson(Map<String, dynamic>.from(row)),
      ],
      pending: [
        if (pending is List)
          for (final row in pending)
            if (row is Map)
              PendingInvite(
                id: row['id']?.toString(),
                name: row['patient_name']?.toString() ?? '',
                relation: row['patient_relation']?.toString() ?? '',
                phone: row['patient_phone']?.toString() ?? '',
              ),
      ],
    );
  }

  /// 어르신이 가족을 초대한다. 어르신이 넣은 것이라 바로 연결된다.
  ///
  /// 서버가 받아 준 뒤에만 "보냈어요"라고 말한다.
  Future<InviteResult> invite({
    required String name,
    required String relation,
    required String phone,
    String? userId,
  }) async {
    final id = (userId ?? MvpSession.userId).trim();
    if (id.isEmpty) {
      return const InviteResult.failed('로그인이 필요해요');
    }
    try {
      await _apiClient.post(
        '/api/v1/guardians',
        body: {
          'user_id': id,
          'guardian_name': name,
          'relationship': relation,
          'phone': phone,
        },
      );
      return InviteResult.sent(
        PendingInvite(name: name, relation: relation, phone: phone),
      );
    } on ApiException catch (error) {
      return InviteResult.failed(error.message);
    } catch (_) {
      return const InviteResult.failed('초대를 보내지 못했어요. 잠시 후 다시 해주세요.');
    }
  }

  /// 보호자가 어르신 번호로 연결을 요청한다. 어르신이 수락해야 열린다.
  Future<InviteResult> requestLink({
    required String relation,
    required String phone,
    String? guardianUserId,
  }) async {
    final id = (guardianUserId ?? MvpSession.userId).trim();
    if (id.isEmpty) {
      return const InviteResult.failed('로그인이 필요해요');
    }
    try {
      final response = await _apiClient.post(
        '/api/v1/guardians/link-requests',
        body: {
          'guardian_user_id': id,
          'patient_phone': phone,
          'patient_relation': relation,
        },
      );
      final data = response is Map ? response : const {};
      return InviteResult.sent(
        PendingInvite(
          id: data['id']?.toString(),
          name: data['patient_name']?.toString() ?? '',
          relation: data['patient_relation']?.toString() ?? relation,
          phone: data['patient_phone']?.toString() ?? phone,
        ),
      );
    } on ApiException catch (error) {
      return InviteResult.failed(error.message);
    } catch (_) {
      return const InviteResult.failed('연결을 요청하지 못했어요. 잠시 후 다시 해주세요.');
    }
  }

  /// 어르신이 보호자의 요청을 수락한다.
  Future<void> accept(String linkId) => _apiClient.patch(
    '/api/v1/guardians/${Uri.encodeComponent(linkId)}',
    body: {'status': 'ACCEPTED'},
  );

  /// 연결 해제 · 요청 취소 · 요청 거절.
  Future<void> remove(String linkId) =>
      _apiClient.delete('/api/v1/guardians/${Uri.encodeComponent(linkId)}');
}
