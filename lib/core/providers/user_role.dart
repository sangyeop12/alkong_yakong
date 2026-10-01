import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 앱 사용자의 역할.
/// 실제로는 회원가입/로그인 시점에 정해지지만,
/// 데모·발표 시연용으로 마이페이지에서 토글할 수 있게 둔다.
enum UserRole { patient, guardian }

/// 현재 사용자 역할. 기본값은 환자.
/// 변경 예: ref.read(userRoleProvider.notifier).state = UserRole.guardian;
final userRoleProvider = StateProvider<UserRole>((ref) => UserRole.patient);
