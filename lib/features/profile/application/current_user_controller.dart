import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/session/mvp_session.dart';
import '../data/user_repository.dart';
import '../domain/user_profile.dart';

final userRepositoryProvider = Provider<UserRepository>(
  (ref) => UserRepository(),
);

/// 지금 로그인한 사람의 정보.
///
/// 이름·나이를 쓰는 화면은 모두 이것만 본다. 고치면 여기 값이 바뀌고
/// 같은 값을 보던 화면이 한꺼번에 다시 그려진다.
final currentUserProvider =
    AsyncNotifierProvider<CurrentUserController, UserProfile?>(
      CurrentUserController.new,
    );

/// 화면에 쓰는 이름. 아직 못 읽었으면 빈 문자열.
final currentUserNameProvider = Provider<String>(
  (ref) => ref.watch(currentUserProvider).valueOrNull?.name ?? '',
);

class CurrentUserController extends AsyncNotifier<UserProfile?> {
  @override
  Future<UserProfile?> build() async {
    final userId = MvpSession.userId.trim();
    if (userId.isEmpty) return null;
    final user = await ref.read(userRepositoryProvider).fetch(userId);
    _syncSession(user);
    return user;
  }

  /// 고친 내용을 서버에 저장한다. 실패하면 예외를 그대로 올려
  /// 화면이 무엇이 잘못됐는지 말하게 한다.
  Future<UserProfile> save(UserProfile edited) async {
    final userId = state.valueOrNull?.id ?? MvpSession.userId.trim();
    final updated = await ref
        .read(userRepositoryProvider)
        .update(userId, edited.toJson());
    _syncSession(updated);
    state = AsyncData(updated);
    return updated;
  }

  void _syncSession(UserProfile user) {
    MvpSession.isPregnant = user.isPregnant;
  }
}
