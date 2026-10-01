import 'package:flutter/foundation.dart';

abstract final class ApiConfig {
  static const String _overrideBaseUrl = String.fromEnvironment('API_BASE_URL');
  static const String _overrideLocalBaseUrl = String.fromEnvironment(
    'LOCAL_API_BASE_URL',
  );
  static const String productionBaseUrl = 'https://alkong-yakong.onrender.com';
  // OCR·약 등록·목록·상세·DUR·복약 기능은 개인 Render를 기본으로 쓴다.
  // 로컬 서버가 필요할 때만 LOCAL_API_BASE_URL dart-define으로 덮어쓴다.
  static const String medicationFeatureBaseUrl =
      'https://alkong-yakong-j0jn.onrender.com';
  static const String desktopDevelopmentBaseUrl = 'http://localhost:8000';

  static String get localFeatureBaseUrl => _overrideLocalBaseUrl.isNotEmpty
      ? _overrideLocalBaseUrl
      : medicationFeatureBaseUrl;

  static String get baseUrl {
    if (_overrideBaseUrl.isNotEmpty) {
      return _overrideBaseUrl;
    }

    if (kIsWeb) {
      return kReleaseMode ? productionBaseUrl : desktopDevelopmentBaseUrl;
    }

    return switch (defaultTargetPlatform) {
      TargetPlatform.android => productionBaseUrl,
      _ => kReleaseMode ? productionBaseUrl : desktopDevelopmentBaseUrl,
    };
  }

  static String get environmentLabel {
    if (_overrideBaseUrl.isNotEmpty) return 'override';
    return kReleaseMode ? 'production' : 'development';
  }
}
