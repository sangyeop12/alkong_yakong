import 'package:flutter/material.dart';
import '../../../../core/widgets/senior_header.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/widgets/senior_feedback.dart';
import '../../../auth/presentation/screens/login_screen.dart';
import '../../../guardian/application/guardians_provider.dart';
import '../../../guardian/data/guardian_repository.dart';

/// 보호자 ↔ 환자 연동 화면.
/// 보호자가 환자의 휴대폰번호로 연결을 요청한다. 환자가 내 정보에서 수락해야
/// 복약 현황이 열린다.
/// 위치: lib/features/dashboard/presentation/screens/patient_link_screen.dart
class PatientLinkScreen extends ConsumerStatefulWidget {
  const PatientLinkScreen({super.key});

  @override
  ConsumerState<PatientLinkScreen> createState() => _PatientLinkScreenState();
}

class _PatientLinkScreenState extends ConsumerState<PatientLinkScreen> {
  final _phone = TextEditingController();
  String? _relation;
  bool _sending = false;

  /// 요청이 서버에 저장된 뒤의 어르신 이름. null이면 아직 보내지 않았다.
  String? _requestedName;

  static const _relations = ['어머니', '아버지', '배우자', '형제자매', '기타'];

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  void _toast(String m, {bool error = false}) =>
      showSeniorSnackbar(context, m, error: error);

  Future<void> _sendRequest() async {
    if (_phone.text.trim().isEmpty) {
      _toast('환자의 휴대폰번호를 입력해주세요', error: true);
      return;
    }
    if (_relation == null) {
      _toast('환자와의 관계를 선택해주세요', error: true);
      return;
    }
    setState(() => _sending = true);
    final result = await GuardianRepository().requestLink(
      relation: _relation!,
      phone: _phone.text.trim(),
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (!result.isSent) {
      _toast(result.error ?? '연결을 요청하지 못했어요', error: true);
      return;
    }
    ref.invalidate(careOverviewProvider);
    setState(() => _requestedName = result.invite!.name);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      // 라벨 없는 화살표 아이콘은 어르신이 버튼으로 인식하지 못한다.
      body: SafeArea(
        child: Column(
          children: [
            const SeniorBackHeader(title: '환자 연결'),
            Expanded(child: _requestedName != null ? _doneView() : _formView()),
          ],
        ),
      ),
    );
  }

  // ── 입력 화면 ──
  Widget _formView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: kGuardianLight,
                borderRadius: BorderRadius.circular(22),
              ),
              child: const Center(
                child: Icon(Icons.link_rounded, color: kGuardian, size: 36),
              ),
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            '돌봐드릴 환자를 연결해주세요',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: kText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '환자가 가입한 휴대폰번호로 연결을 요청하면,\n환자가 수락한 뒤 복약 현황을 볼 수 있어요.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[500],
              height: 1.5,
            ),
          ),
          const SizedBox(height: 28),

          _label('환자 휴대폰번호'),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            inputFormatters: [PhoneNumberFormatter()],
            style: const TextStyle(fontSize: 16),
            decoration: InputDecoration(
              hintText: '010-0000-0000',
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 16,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: Colors.grey[300]!),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: kGuardian, width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 20),

          _label('나와의 관계'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final r in _relations)
                GestureDetector(
                  onTap: () => setState(() => _relation = r),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: _relation == r
                          ? kGuardian.withValues(alpha: 0.10)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _relation == r ? kGuardian : Colors.grey[300]!,
                        width: _relation == r ? 1.5 : 1,
                      ),
                    ),
                    child: Text(
                      r,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: _relation == r ? kGuardian : kText,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 32),

          SizedBox(
            height: 56,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: kGuardian,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: _sending ? null : _sendRequest,
              child: Text(
                _sending ? '보내는 중...' : '연결 요청 보내기',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 요청 완료 화면 ──
  Widget _doneView() {
    final name = _requestedName!.isEmpty ? _phone.text : '$_requestedName';
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(),
          Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: kGuardianLight,
                shape: BoxShape.circle,
              ),
              child: const Center(
                child: Icon(Icons.send_rounded, color: kGuardian, size: 40),
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            '연결 요청을 보냈어요',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: kText,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '$name 님에게 요청을 보냈어요.\n환자가 내 정보에서 수락하면 복약 현황을 볼 수 있어요.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[500],
              height: 1.5,
            ),
          ),
          const Spacer(),
          SizedBox(
            height: 56,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: kGuardian,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text(
                '확인',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 8, left: 4),
    child: Text(
      t,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: kText,
      ),
    ),
  );
}
