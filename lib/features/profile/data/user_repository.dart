import '../../../core/network/api_client.dart';
import '../domain/user_profile.dart';

/// 가입 · 로그인 · 내 정보 읽기/고치기 · 탈퇴.
class UserRepository {
  UserRepository({ApiClient? apiClient}) : _api = apiClient ?? ApiClient();

  final ApiClient _api;

  static String _path(String userId) =>
      '/api/v1/users/${Uri.encodeComponent(userId)}';

  Future<UserProfile> fetch(String userId) async =>
      _profile(await _api.get(_path(userId)));

  Future<UserProfile> signUp(Map<String, dynamic> body) async => _profile(
    await _api.post(
      '/api/v1/users',
      body: body,
      timeout: const Duration(seconds: 15),
    ),
  );

  Future<UserProfile> login({
    required String phone,
    required String password,
  }) async => _profile(
    await _api.post(
      '/api/v1/users/login',
      body: {'phone': phone, 'password': password},
      timeout: const Duration(seconds: 15),
    ),
  );

  Future<UserProfile> update(
    String userId,
    Map<String, dynamic> changes,
  ) async => _profile(await _api.patch(_path(userId), body: changes));

  Future<void> delete(String userId) => _api.delete(_path(userId));

  static UserProfile _profile(dynamic response) {
    if (response is Map) {
      final data = Map<String, dynamic>.from(response);
      final id = data['id']?.toString().trim() ?? '';
      final role = data['role']?.toString().trim().toLowerCase();
      if (id.isNotEmpty &&
          id != 'mvp-user' &&
          (role == 'patient' || role == 'guardian')) {
        return UserProfile.fromJson(data);
      }
    }
    throw const ApiException('서버에서 내 정보를 받지 못했어요.');
  }
}
