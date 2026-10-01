import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 앱 사용 모드.
///
/// 두 모드는 **같은 화면을 쓴다.** 다른 것은 화면 사이를 오가는 방법뿐이다.
/// - [normal] 아래 탭으로 원하는 화면에 바로 간다. 어디로든 갈 수 있는 대신
///   "지금 무엇을 해야 하는가"는 사용자가 판단해야 한다.
/// - [easy] 화면이 한 줄로 이어진다. 큰 버튼 하나만 누르면 다음 화면으로
///   넘어가고, 길을 고를 필요가 없다.
enum AppMode {
  normal,
  easy;

  String get label => switch (this) {
    AppMode.normal => '일반 모드',
    AppMode.easy => '쉬운 모드',
  };

  /// 설정 화면에서 보여줄 한 줄 설명.
  String get description => switch (this) {
    AppMode.normal => '아래 탭으로 원하는 곳에 바로 갑니다',
    AppMode.easy => '버튼 하나로 다음 화면까지 안내합니다',
  };

  bool get isEasy => this == AppMode.easy;
}

/// 저장 키. 앱을 껐다 켜도 고른 모드가 유지된다.
const String _kAppModeKey = 'appMode';

class AppModeNotifier extends StateNotifier<AppMode> {
  AppModeNotifier() : super(AppMode.normal) {
    _load();
  }

  SharedPreferences? _prefs;

  Future<void> _load() async {
    _prefs = await SharedPreferences.getInstance();
    final saved = _prefs?.getString(_kAppModeKey);
    if (saved == AppMode.easy.name) {
      state = AppMode.easy;
    }
  }

  Future<void> set(AppMode mode) async {
    if (state == mode) return;
    state = mode;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs?.setString(_kAppModeKey, mode.name);
  }

  Future<void> toggle() => set(state.isEasy ? AppMode.normal : AppMode.easy);
}

/// 현재 사용 모드. 기본은 일반 모드.
final appModeProvider = StateNotifierProvider<AppModeNotifier, AppMode>(
  (ref) => AppModeNotifier(),
);
