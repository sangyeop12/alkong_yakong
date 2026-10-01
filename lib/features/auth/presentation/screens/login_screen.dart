import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/app_logo.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_feedback.dart';
import '../../../profile/application/current_user_controller.dart';
import '../../../profile/application/session_actions.dart';
import 'signup_screen.dart';

/// 4i — 로그인 · 시작하기.
///
/// 프로토타입대로 전화번호·비밀번호·시작하기만 둔다.
/// 가족이 대신 만들어 드리는 길은 가입 화면 안에서 잇는다.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _phone = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _loggingIn = false;

  @override
  void dispose() {
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_phone.text.trim().isEmpty || _password.text.isEmpty) {
      showSeniorSnackbar(context, '전화번호와 비밀번호를 넣어주세요', error: true);
      return;
    }
    if (_loggingIn) return;

    setState(() => _loggingIn = true);
    try {
      final user = await ref
          .read(userRepositoryProvider)
          .login(phone: _phone.text.trim(), password: _password.text);
      if (!mounted) return;
      await startSession(ref, user);
      if (mounted) context.go('/');
    } on ApiException catch (error) {
      if (!mounted) return;
      showSeniorSnackbar(context, error.message, error: true);
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: AppLogo(size: 72),
              ),
              const SizedBox(height: 18),
              Text('알콩약콩', style: AppText.screenTitle(size: 36)),
              const SizedBox(height: 8),
              Text(
                '약 드실 시간을 알려드리고,\n가족이 함께 챙겨드려요.',
                style: AppText.body(size: 21, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 34),

              _FieldLabel('전화번호'),
              _SeniorField(
                controller: _phone,
                hint: '010-0000-0000',
                keyboardType: TextInputType.phone,
                // 숫자 키패드 강제 + 자동 하이픈.
                inputFormatters: [PhoneNumberFormatter()],
              ),
              const SizedBox(height: 20),

              _FieldLabel('비밀번호'),
              _SeniorField(
                controller: _password,
                hint: '비밀번호',
                obscure: _obscure,
                // 아이콘 대신 한글 라벨 — 눈 모양 아이콘은 학습이 안 된다.
                suffix: SeniorTextButton(
                  label: _obscure ? '보기' : '숨기기',
                  color: AppColors.point,
                  // 가로를 채우지 않고 글자 폭만 차지해야 오른쪽에 붙는다.
                  expand: false,
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              const SizedBox(height: 26),

              SeniorButton(
                label: _loggingIn ? '들어가는 중...' : '시작하기',
                minHeight: 74,
                fontSize: 25,
                onPressed: _loggingIn ? null : _login,
              ),
              const SizedBox(height: 18),

              Center(
                child: InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SignupScreen(),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                    child: Text.rich(
                      TextSpan(
                        style: AppText.label(
                          size: 19,
                          color: AppColors.textSecondary,
                        ),
                        children: [
                          const TextSpan(text: '처음이세요?  '),
                          TextSpan(
                            text: '가입하기',
                            style: AppText.label(
                              size: 19,
                              color: AppColors.point,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 30),

              // 화면 확인용 임시 단추. 개발 빌드에서만 보인다.
              // 확인이 끝나면 이 블록과 /demo-guardian, demo_guardian.dart 를 지운다.
              if (kDebugMode) ...[
                const SizedBox(height: 18),
                SeniorButton(
                  label: '화면 확인용 · 보호자 화면',
                  kind: SeniorButtonKind.neutral,
                  minHeight: 56,
                  fontSize: 18,
                  onPressed: () => context.push('/demo-guardian'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: AppText.label()),
  );
}

/// 높이 66, bg 배경, 2px 테두리, 값 22px/700.
class _SeniorField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final Widget? suffix;

  const _SeniorField({
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.keyboardType,
    this.inputFormatters,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 66),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border, width: 2),
      ),
      // "보기" 같은 우측 버튼이 붙으면 오른쪽 여백을 줄여 버튼을 테두리 쪽으로
      // 붙인다. 버튼 자체의 탭 영역은 그대로 48px를 넘긴다.
      padding: EdgeInsets.only(left: 20, right: suffix == null ? 20 : 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: obscure,
              keyboardType: keyboardType,
              inputFormatters: inputFormatters,
              style: AppText.label(size: 22, color: AppColors.textPrimary),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                hintText: hint,
                hintStyle: AppText.label(
                  size: 22,
                  color: AppColors.textTertiary,
                ),
              ),
            ),
          ),
          if (suffix != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 92),
              child: suffix!,
            ),
        ],
      ),
    );
  }
}

/// 전화번호 입력에 자동으로 하이픈을 넣는다. 어르신이 직접 `-`를 찾지 않도록.
class PhoneNumberFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    final capped = digits.length > 11 ? digits.substring(0, 11) : digits;

    final buffer = StringBuffer();
    for (int i = 0; i < capped.length; i++) {
      if (i == 3 ||
          (i == 7 && capped.length > 10) ||
          (i == 6 && capped.length <= 10)) {
        buffer.write('-');
      }
      buffer.write(capped[i]);
    }
    final text = buffer.toString();

    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
