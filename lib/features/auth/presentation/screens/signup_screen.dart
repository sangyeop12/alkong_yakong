import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/constants/app_colors.dart';
import '../../domain/exclusive_choice.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/providers/user_role.dart';
import '../../../../core/session/auth_session.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/senior_button.dart';
import '../../../../core/widgets/senior_feedback.dart';
import '../../../../core/widgets/senior_wheel.dart';
import '../../../../core/widgets/senior_header.dart';
import '../../../guardian/application/guardians_provider.dart';
import '../../../guardian/data/guardian_repository.dart';
import '../../../profile/application/session_actions.dart';
import '../../../profile/domain/user_profile.dart';

/// 병력 선택값과 기존 불리언 계약을 함께 보낸다.
Map<String, dynamic> buildIllnessHistoryPayload({
  required Iterable<String> pastIllnesses,
  required Iterable<String> familyIllnesses,
}) {
  List<String> selected(Iterable<String> values) => [
    for (final value in values)
      if (value.trim().isNotEmpty && value.trim() != '없어요') value.trim(),
  ];

  final past = selected(pastIllnesses);
  final family = selected(familyIllnesses);
  return {
    'past_illnesses': past,
    'family_illnesses': family,
    'past_history': past.isNotEmpty,
    'family_history': family.isNotEmpty,
  };
}

/// 단계형 회원가입 (위저드).
/// 위치: lib/features/auth/presentation/screens/signup_screen.dart
class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  int _step = 0;

  /// 아래 버튼 영역. 오류 스낵바를 이 높이만큼 올려 버튼을 가리지 않는다.
  final _actionsKey = GlobalKey();
  bool _isSubmitting = false;
  final ApiClient _apiClient = ApiClient();

  /// 처음에는 아무것도 고르지 않은 상태다. 기본값이 있으면
  /// 고르지 않고 지나쳐도 환자로 가입된다.
  String _role = 'patient';
  bool _rolePicked = false;
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _pw = TextEditingController();
  bool _obscure = true;
  DateTime? _birth;
  String? _gender;

  final _height = TextEditingController();
  final _weight = TextEditingController();
  String? _blood;

  String? _pregnancy;
  String? _smoking;
  String? _drinking;

  bool? _allergyYes;
  final Set<String> _allergens = {};
  final _allergyOther = TextEditingController();

  final _diseaseOther = TextEditingController();

  /// 과거에 앓았던 병과 부모·형제가 앓은 병.
  /// "없어요"는 다른 것과 함께 고를 수 없다.
  final Set<String> _pastIllnesses = {};
  final Set<String> _familyIllnesses = {};

  static const _pastOptions = ['암', '뇌졸중', '심근경색', '간·콩팥병', '없어요'];

  static const _familyOptions = ['고혈압', '당뇨', '암', '심장병', '치매', '없어요'];

  final Set<String> _diseases = {};

  // 보호자 연락처. 나중에 등록해도 되므로 건너뛴 사실도 기억한다.
  final _guardianName = TextEditingController();
  final _guardianPhone = TextEditingController();
  String? _guardianRelation;
  bool _guardianLater = false;

  bool _agreeTerms = false;
  bool _agreePrivacy = false;
  bool _agreeAge = false;
  bool _agreeMarketing = false;
  bool get _allRequired => _agreeAge && _agreeTerms && _agreePrivacy;
  bool get _allChecked => _allRequired && _agreeMarketing;

  static const _allergyOptions = ['페니실린', '아스피린', '소염진통제', '조영제', '잘 모르겠어요'];
  static const _diseaseOptions = ['고혈압', '당뇨', '고지혈증', '심장병', '콩팥병', '없어요'];

  @override
  void dispose() {
    _guardianName.dispose();
    _guardianPhone.dispose();
    _name.dispose();
    _phone.dispose();
    _pw.dispose();
    _height.dispose();
    _weight.dispose();
    _allergyOther.dispose();
    _diseaseOther.dispose();
    super.dispose();
  }

  void _toggle(Set<String> set, String o) => setState(() {
    final next = toggleChoice(set, o);
    set
      ..clear()
      ..addAll(next);
  });

  Future<void> _pickBirth() async {
    final picked = await showSeniorDateWheel(
      context: context,
      initialDate: _birth,
    );
    if (picked == null) return;
    setState(() => _birth = picked);
  }

  void _next(List<_StepDef> steps) {
    final err = steps[_step].validate();
    if (err != null) {
      _showError(err);
      return;
    }
    if (_step >= steps.length - 1) {
      _submit();
    } else {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      setState(() => _step++);
    }
  }

  void _prev() {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (_step == 0) {
      Navigator.of(context).maybePop();
    } else {
      setState(() => _step--);
    }
  }

  /// 틀린 곳 한 군데를 스낵바로 알린다. 아래 버튼을 가리지 않도록 그 위에 띄운다.
  void _showError(String message) {
    final actionsHeight = _actionsKey.currentContext?.size?.height ?? 0;
    showSeniorSnackbar(context, message, error: true, bottom: actionsHeight);
  }

  String? _optionalTrimmed(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// 가입 화면에서 받은 것을 빠짐없이 서버로 보낸다.
  /// 건강 질문은 약을 드시는 분에게만 묻는다.
  Map<String, dynamic> _signupBody() {
    final body = <String, dynamic>{
      'name': _name.text.trim(),
      'role': _role,
      'phone': _optionalTrimmed(_phone.text),
      'password': _pw.text,
    };
    if (_role != 'patient') return body;
    return body..addAll({
      'birth_date': UserProfile.formatDate(_birth),
      'gender': _gender,
      'height_cm': double.tryParse(_height.text.trim()),
      'weight_kg': double.tryParse(_weight.text.trim()),
      'blood_type': _blood,
      'pregnancy_status': _gender == 'F' ? _pregnancy : null,
      'smoking': _smoking,
      'drinking': _drinking,
      'allergies': _allergyYes == true
          ? _picked(_allergens, _allergyOther, skip: '잘 모르겠어요')
          : <String>[],
      'diseases': _picked(_diseases, _diseaseOther, skip: '없어요'),
      ...buildIllnessHistoryPayload(
        pastIllnesses: _pastIllnesses,
        familyIllnesses: _familyIllnesses,
      ),
    });
  }

  /// "기타"는 적어 준 글자로 바꾸고, 약·병 이름이 아닌 보기는 뺀다.
  List<String> _picked(
    Set<String> chosen,
    TextEditingController other, {
    required String skip,
  }) => [
    for (final item in chosen)
      if (item == '기타') other.text.trim() else if (item != skip) item,
  ].where((item) => item.isNotEmpty).toList();

  /// 가입 단계에서 적어 준 보호자를 등록한다. 가입은 이미 끝났으니
  /// 실패해도 막지 않고, 내 정보에서 다시 초대하면 된다고만 알린다.
  Future<void> _saveGuardianContact() async {
    final name = _guardianName.text.trim();
    if (_role != 'patient' || _guardianLater || name.isEmpty) return;
    final result = await GuardianRepository().invite(
      name: name,
      relation: _guardianRelation ?? '그 외',
      phone: _guardianPhone.text.trim(),
    );
    ref.invalidate(guardiansProvider);
    if (!result.isSent && mounted) {
      showSeniorSnackbar(
        context,
        '보호자 연락처는 저장하지 못했어요. 내 정보에서 다시 초대해 주세요.',
        error: true,
      );
    }
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);

    try {
      final body = _signupBody();

      final response = await _apiClient.post('/api/v1/users', body: body);
      final userId = response is Map<String, dynamic>
          ? response['id']?.toString()
          : null;
      if (userId == null || userId.isEmpty) {
        throw const ApiException('회원가입 응답에 사용자 ID가 없습니다.');
      }

      await AuthSession.persistUserId(userId);
      // 가입한 역할대로 로그인 상태를 만든다. 보호자로 가입하면 보호자 화면이 열린다.
      await AuthSession.setLoggedIn(_role);
      if (mounted) {
        ref.read(userRoleProvider.notifier).state = _role == 'guardian'
            ? UserRole.guardian
            : UserRole.patient;
        // 방금 만든 계정으로 바뀌었으니 앞사람의 약·가족·기록은 버린다.
        resetUserScopedData(ref);
      }
      await _saveGuardianContact();
      if (!mounted) return;
      // 가입 완료 화면이 다음 길(약 등록 / 나중에 하기)을 스스로 정한다.
      // 여기서 또 옮기면 방금 연 화면이 곧바로 로그인으로 덮인다.
      await _showSignupComplete();
    } catch (error) {
      if (!mounted) return;
      _showError('회원가입에 실패했습니다: $error');
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  /// 가입이 끝났다는 사실만 알리고, 다음 한 걸음을 바로 내민다.
  /// 확인만 누르고 사라지는 알림창은 아무것도 이어주지 않는다.
  Future<void> _showSignupComplete() {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SignupDoneScreen(name: _name.text.trim()),
      ),
    );
  }

  List<_StepDef> _buildSteps() {
    final steps = <_StepDef>[
      _StepDef(
        title: '어떤 분이신가요?',
        subtitle: '고르시면 물어보는 것이 달라집니다.',
        validate: () => _rolePicked ? null : '어떤 분인지 골라주세요',
        // 둘을 나란히 두면 칸이 좁아 설명이 두세 줄로 접힌다.
        // 위아래로 쌓아 한 줄씩 읽게 둔다.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _roleCard('patient', '약을 드시는 분', '내가 먹는 약을 등록하고 알림을 받습니다'),
            const SizedBox(height: 12),
            _roleCard('guardian', '돌보는 가족(보호자)', '부모님 복약과 심박수를 함께 봅니다'),
          ],
        ),
      ),
      _StepDef(
        title: '기본 정보를\n알려주세요',
        subtitle: '번호는 로그인과 약 알림에 씁니다.',
        validate: () {
          if (_name.text.trim().isEmpty) return '이름을 입력해주세요';
          if (_phone.text.trim().isEmpty) return '휴대폰 번호를 입력해주세요';
          if (_pw.text.isEmpty) return '비밀번호를 입력해주세요';
          if (_pw.text.length < 6) return '비밀번호는 6자 이상이어야 해요';
          return null;
        },
        child: Column(
          children: [
            _field(_name, label: '이름', hint: '성함'),
            const SizedBox(height: 12),
            // 인증 버튼은 두지 않는다. 여기서 문자를 기다리게 하면
            // 가입이 끊긴다 — 번호 확인은 첫 알림이 도착하는 것으로 갈음한다.
            _field(
              _phone,
              label: '휴대폰 번호',
              hint: '010-0000-0000',
              keyboard: TextInputType.phone,
            ),
            const SizedBox(height: 12),
            _field(
              _pw,
              label: '비밀번호 (6자 이상)',
              hint: '비밀번호',
              obscure: _obscure,
              // 눈 모양 아이콘은 학습이 안 된다. 한글 라벨로 둔다.
              suffix: SeniorTextButton(
                label: _obscure ? '보기' : '숨기기',
                color: AppColors.point,
                expand: false,
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ],
        ),
      ),
    ];

    // 환자만 건강정보 단계를 받는다 (보호자는 환자 모니터링 전용이라 불필요)
    if (_role == 'patient') {
      steps.addAll([
        _StepDef(
          title: '생년월일과 성별을\n알려주세요',
          subtitle: '나이에 따라 주의할 약이 달라요.',
          validate: () {
            if (_birth == null) return '생년월일을 골라주세요';
            if (_gender == null) return '성별을 골라주세요';
            return null;
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                button: true,
                label: _birth == null
                    ? '생년월일 고르기'
                    : '생년월일 ${_birth!.year}년 ${_birth!.month}월 '
                          '${_birth!.day}일, 바꾸기',
                child: GestureDetector(
                  onTap: _pickBirth,
                  child: ExcludeSemantics(
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 66),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.bg,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: AppColors.border, width: 2),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _birth == null
                                  ? '생년월일'
                                  : '${_birth!.year}년 ${_birth!.month}월 '
                                        '${_birth!.day}일',
                              style: AppText.label(
                                size: 22,
                                color: _birth == null
                                    ? AppColors.textTertiary
                                    : AppColors.textPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          const Icon(
                            TablerIcons.calendar_month,
                            size: 24,
                            color: AppColors.textTertiary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _pill(
                        '여자',
                        _gender == 'F',
                        () => setState(() => _gender = 'F'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _pill(
                        '남자',
                        _gender == 'M',
                        () => setState(() => _gender = 'M'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        _StepDef(
          title: '키와 몸무게,\n혈액형을 알려주세요',
          subtitle: '약 용량을 볼 때 씁니다.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 두 칸을 나란히 두되 각자 최소 높이를 지킨다.
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _field(
                        _height,
                        label: '키',
                        hint: '키',
                        keyboard: TextInputType.number,
                        suffixText: 'cm',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _field(
                        _weight,
                        label: '몸무게',
                        hint: '몸무게',
                        keyboard: TextInputType.number,
                        suffixText: 'kg',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _sectionLabel('혈액형'),
              _grid(
                const ['A형', 'B형', 'O형', 'AB형', '몰라요'],
                _blood,
                (v) => setState(() => _blood = v),
              ),
            ],
          ),
        ),
      ]);

      // 임신·수유 여부는 병용금기 판정을 통째로 바꾼다. 건너뛰지 않는다.
      if (_gender == 'F') {
        steps.add(
          _StepDef(
            title: '지금 임신 중이거나\n젖을 먹이고 계신가요?',
            subtitle: '이때는 피해야 하는 약이 있어요.',
            validate: () => _pregnancy == null ? '해당하는 것을 골라주세요' : null,
            child: _grid(
              const ['임신 중이에요', '젖을 먹이고 있어요', '둘 다 아니에요'],
              _pregnancy,
              (v) => setState(() => _pregnancy = v),
            ),
          ),
        );
      }

      steps.addAll([
        _StepDef(
          title: '담배와 술은\n어떠신가요?',
          subtitle: '약과 함께 있으면 조심할 것이 있어요.',
          validate: () {
            if (_smoking == null) return '담배를 피우시는지 골라주세요';
            if (_drinking == null) return '술을 얼마나 드시는지 골라주세요';
            return null;
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sectionLabel('담배'),
              _grid(
                const ['안 펴요', '펴요', '끊었어요'],
                _smoking,
                (v) => setState(() => _smoking = v),
              ),
              const SizedBox(height: 18),
              _sectionLabel('술'),
              _grid(
                const ['안 마셔요', '가끔 마셔요', '자주 마셔요'],
                _drinking,
                (v) => setState(() => _drinking = v),
              ),
            ],
          ),
        ),
        _StepDef(
          title: '약물 알레르기가\n있으신가요?',
          subtitle: '위험한 약을 걸러내는 데 꼭 필요합니다.',
          validate: () {
            if (_allergyYes == null) return '있는지 없는지 골라주세요';
            if (_allergyYes == true && _allergens.isEmpty) {
              return '어떤 약인지 하나 이상 골라주세요';
            }
            if (_allergens.length > 1 && _allergens.contains('잘 모르겠어요')) {
              return '"잘 모르겠어요"는 약 이름과 함께 고를 수 없어요';
            }
            return null;
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _yesNo(_allergyYes, (v) => setState(() => _allergyYes = v)),
              if (_allergyYes == true) ...[
                const SizedBox(height: 16),
                Text(
                  '어떤 약인지 눌러주세요 (여러 개 가능)',
                  style: AppText.caption(size: 17.5),
                ),
                const SizedBox(height: 10),
                _multiChips(
                  _allergyOptions,
                  _allergens,
                  (o) => _toggle(_allergens, o),
                ),
              ],
            ],
          ),
        ),
        _StepDef(
          // "있으신가요?"를 먼저 묻고 다시 고르게 하면 두 번 묻는 셈이 된다.
          // "없어요"를 칩 안에 넣어 한 번에 끝낸다.
          title: '지금 앓고 있는\n병이 있으신가요?',
          subtitle: '약을 함께 먹어도 되는지 판단할 때 씁니다.',
          validate: () {
            if (_diseases.isEmpty) {
              return '해당하는 것을 고르거나 "없어요"를 눌러주세요';
            }
            if (_diseases.length > 1 && _diseases.contains('없어요')) {
              return '지병과 "없어요"는 함께 고를 수 없어요';
            }
            return null;
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _multiChips(
                _diseaseOptions,
                _diseases,
                (o) => _toggle(_diseases, o),
              ),
            ],
          ),
        ),
      ]);
      steps.add(
        _StepDef(
          title: '과거에 앓았던 병이\n있나요?',
          subtitle: '지금은 다 나으셨더라도 골라주세요. 없으면 "없어요"를 눌러주세요.',
          validate: () {
            if (_pastIllnesses.isEmpty) {
              return '과거에 앓았던 병을 고르거나 "없어요"를 눌러주세요';
            }
            return null;
          },
          child: _multiChips(
            _pastOptions,
            _pastIllnesses,
            (o) => _toggle(_pastIllnesses, o),
          ),
        ),
      );

      steps.add(
        _StepDef(
          title: '가족이 앓은 병이\n있나요?',
          subtitle: '부모·형제 이야기입니다. 해당이 없으면 "없어요"를 눌러주세요.',
          validate: () {
            if (_familyIllnesses.isEmpty) {
              return '가족이 앓은 병을 고르거나 "없어요"를 눌러주세요';
            }
            return null;
          },
          child: _multiChips(
            _familyOptions,
            _familyIllnesses,
            (o) => _toggle(_familyIllnesses, o),
          ),
        ),
      );

      steps.add(
        _StepDef(
          title: '보호자 연락처를\n알려주세요',
          subtitle:
              '약을 놓치거나 심박수가 빠를 때 이 분에게 알려드립니다. '
              '나중에 등록해도 됩니다.',
          validate: () {
            if (_guardianLater) return null;
            if (_guardianName.text.trim().isEmpty &&
                _guardianRelation == null &&
                _guardianPhone.text.trim().isEmpty) {
              return '보호자를 등록하거나 "나중에 등록할게요"를 눌러주세요';
            }
            if (_guardianName.text.trim().isEmpty) {
              return '보호자 성함을 입력해주세요';
            }
            if (_guardianRelation == null) return '나와의 관계를 골라주세요';
            if (_guardianPhone.text.trim().isEmpty) {
              return '보호자 휴대폰 번호를 입력해주세요';
            }
            return null;
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _field(_guardianName, label: '성함', hint: '보호자 성함'),
              const SizedBox(height: 12),
              _sectionLabel('나와의 관계'),
              _multiChips(
                const ['딸', '아들', '배우자', '그 외'],
                {?_guardianRelation},
                (o) => setState(() {
                  _guardianRelation = _guardianRelation == o ? null : o;
                  _guardianLater = false;
                }),
              ),
              const SizedBox(height: 12),
              _field(
                _guardianPhone,
                label: '휴대폰 번호',
                hint: '010-0000-0000',
                keyboard: TextInputType.phone,
              ),
              const SizedBox(height: 16),
              SeniorButton(
                label: _guardianLater ? '나중에 등록할게요 ✓' : '나중에 등록할게요',
                kind: SeniorButtonKind.secondary,
                minHeight: 62,
                fontSize: 20,
                onPressed: () => setState(() {
                  _guardianLater = !_guardianLater;
                  if (_guardianLater) {
                    _guardianName.clear();
                    _guardianPhone.clear();
                    _guardianRelation = null;
                  }
                }),
              ),
            ],
          ),
        ),
      );
    } // 환자 전용 건강정보 단계 끝

    // 동의는 환자·보호자 공통
    steps.addAll([
      _StepDef(
        title: '약관에\n동의해주세요',
        subtitle: '필수 3개에 동의하면 가입이 끝납니다.',
        validate: () => _allRequired ? null : '필수 3개에 동의해주세요',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 한 번에 끝내는 길을 맨 위에 크게 둔다.
            Semantics(
              button: true,
              checked: _allChecked,
              child: GestureDetector(
                onTap: () {
                  final v = !_allChecked;
                  setState(() {
                    _agreeAge = v;
                    _agreeTerms = v;
                    _agreePrivacy = v;
                    _agreeMarketing = v;
                  });
                },
                child: ExcludeSemantics(
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 70),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: _allChecked
                          ? AppColors.pointTint
                          : AppColors.surface,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: _allChecked
                            ? AppColors.point
                            : AppColors.strongBorder,
                        width: 2,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _allChecked
                              ? TablerIcons.circle_check_filled
                              : TablerIcons.circle,
                          size: 32,
                          color: _allChecked
                              ? AppColors.point
                              : AppColors.inactive,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '전체 동의하기',
                            style: AppText.cardTitle(size: 20),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _consent(
              '만 14세 이상입니다',
              _agreeAge,
              (v) => setState(() => _agreeAge = v),
              required: true,
            ),
            _consent(
              '서비스 이용약관 동의',
              _agreeTerms,
              (v) => setState(() => _agreeTerms = v),
              required: true,
            ),
            _consent(
              '개인정보 수집·이용 동의',
              _agreePrivacy,
              (v) => setState(() => _agreePrivacy = v),
              required: true,
            ),
            _consent(
              '마케팅 정보 수신 동의',
              _agreeMarketing,
              (v) => setState(() => _agreeMarketing = v),
              required: false,
            ),
          ],
        ),
      ),
    ]);

    return steps;
  }

  @override
  Widget build(BuildContext context) {
    final steps = _buildSteps();
    if (_step > steps.length - 1) _step = steps.length - 1;
    final cur = steps[_step];
    final isLast = _step == steps.length - 1;

    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Column(
          children: [
            SeniorHeader(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 뒤로 버튼이 라벨을 갖게 되면서 한 줄에 셋을 넣으면
                  // 글자가 커질 때 넘친다. 걸음 표시를 아래로 내린다.
                  Row(
                    children: [
                      SeniorBackButton(onTap: _prev),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          '회원가입',
                          style: AppText.screenTitle(size: 24),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${_step + 1} / ${steps.length}',
                    style: AppText.cardTitle(
                      size: 18,
                      color: AppColors.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: (_step + 1) / steps.length,
                      minHeight: 8,
                      backgroundColor: AppColors.secondaryFill,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        AppColors.point,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 한 화면에 하나만 묻는다.
                    Text(cur.title, style: AppText.screenTitle(size: 27)),
                    if (cur.subtitle != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        cur.subtitle!,
                        style: AppText.body(
                          size: 18,
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    cur.child,
                  ],
                ),
              ),
            ),
            Padding(
              key: _actionsKey,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SeniorButton(
                    label: isLast && _isSubmitting
                        ? '가입 중...'
                        : isLast
                        ? '가입하기'
                        : '다음',
                    minHeight: 74,
                    fontSize: 24,
                    onPressed: _isSubmitting ? null : () => _next(steps),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 공통 위젯 ─────────────────────────────────────────────
  //
  // 단계 정의는 모두 이 일곱 개를 통과한다. 여기만 시니어 규격으로
  // 맞추면 일곱 단계가 한꺼번에 따라온다.

  Widget _field(
    TextEditingController c, {
    String? label,
    String? hint,
    bool obscure = false,
    TextInputType? keyboard,
    Widget? suffix,
    String? suffixText,
  }) {
    return SeniorField(
      controller: c,
      label: label,
      hint: hint,
      obscure: obscure,
      keyboardType: keyboard,
      suffix:
          suffix ??
          (suffixText == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(right: 18),
                  child: Text(suffixText, style: AppText.label(size: 18)),
                )),
    );
  }

  /// 0단계 역할 카드. 최소 104, 아이콘 36.
  Widget _roleCard(String role, String title, String sub) {
    final selected = _rolePicked && _role == role;
    return Semantics(
      button: true,
      selected: selected,
      label: '$title, $sub',
      child: GestureDetector(
        onTap: () => setState(() {
          _role = role;
          _rolePicked = true;
        }),
        child: ExcludeSemantics(
          child: Container(
            constraints: const BoxConstraints(minHeight: 104),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
            decoration: BoxDecoration(
              color: selected ? AppColors.pointTint : AppColors.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: selected ? AppColors.point : AppColors.strongBorder,
                width: 2,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  role == 'guardian' ? TablerIcons.users : TablerIcons.user,
                  size: 32,
                  color: selected ? AppColors.point : AppColors.textTertiary,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: AppText.cardTitle(
                          size: 20,
                          color: selected
                              ? AppColors.point
                              : AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(sub, style: AppText.caption(size: 17)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _pill(
    String label,
    bool selected,
    VoidCallback onTap, {
    double minHeight = 74,
  }) {
    return Semantics(
      button: true,
      selected: selected,
      label: '$label ${selected ? '고름' : '고르지 않음'}',
      child: GestureDetector(
        onTap: onTap,
        child: ExcludeSemantics(
          child: Container(
            constraints: BoxConstraints(minHeight: minHeight),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            decoration: BoxDecoration(
              color: selected ? AppColors.point : AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected
                    ? AppColors.pointBorder
                    : AppColors.strongBorder,
                width: 2,
              ),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: AppText.cardTitle(
                size: 19,
                color: selected ? Colors.white : AppColors.textBody,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 단계 안의 작은 제목. 한 걸음에 두 가지를 물을 때만 쓴다.
  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: AppText.label(size: 18)),
  );

  /// 두 칸씩 늘어놓는 단일 선택. 글자가 길면 그 보기만 한 줄을 다 쓴다.
  Widget _grid(
    List<String> options,
    String? selected,
    ValueChanged<String> onSelect,
  ) {
    return _OptionFlow(
      options: options,
      builder: (option, full) => _pill(
        option,
        selected == option,
        () => onSelect(option),
        minHeight: 64,
      ),
    );
  }

  Widget _multiChips(
    List<String> options,
    Set<String> selected,
    void Function(String) onTap,
  ) {
    return _OptionFlow(
      options: options,
      builder: (option, full) {
        final picked = selected.contains(option);
        return Semantics(
          button: true,
          selected: picked,
          label: '$option ${picked ? '고름' : '고르지 않음'}',
          child: GestureDetector(
            onTap: () => onTap(option),
            child: ExcludeSemantics(
              child: Container(
                constraints: const BoxConstraints(minHeight: 64),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: picked ? AppColors.point : AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: picked
                        ? AppColors.pointBorder
                        : AppColors.strongBorder,
                    width: 2,
                  ),
                ),
                child: Text(
                  option,
                  textAlign: TextAlign.center,
                  style: AppText.cardTitle(
                    size: 18,
                    color: picked ? Colors.white : AppColors.textBody,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _yesNo(bool? value, ValueChanged<bool> onSelect) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _pill('있어요', value == true, () => onSelect(true))),
          const SizedBox(width: 10),
          Expanded(child: _pill('없어요', value == false, () => onSelect(false))),
        ],
      ),
    );
  }

  /// 약관 한 줄. 필수·선택 태그를 오른쪽에 둔다.
  Widget _consent(
    String label,
    bool value,
    ValueChanged<bool> onChanged, {
    required bool required,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        checked: value,
        label: '${required ? '필수' : '선택'} $label',
        child: GestureDetector(
          onTap: () => onChanged(!value),
          child: ExcludeSemantics(
            child: Container(
              constraints: const BoxConstraints(minHeight: 64),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.sunken,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Icon(
                    value
                        ? TablerIcons.circle_check_filled
                        : TablerIcons.circle,
                    size: 28,
                    color: value ? AppColors.point : AppColors.inactive,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(label, style: AppText.label(size: 18))),
                  const SizedBox(width: 10),
                  Text(
                    required ? '필수' : '선택',
                    style: AppText.cardTitle(
                      size: 17,
                      color: required
                          ? AppColors.point
                          : AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StepDef {
  final String title;
  final String? subtitle;
  final Widget child;
  final String? Function() validate;

  _StepDef({
    required this.title,
    this.subtitle,
    required this.child,
    String? Function()? validate,
  }) : validate = (validate ?? (() => null));
}

/// 회원가입 완료.
///
/// 가입이 끝난 자리에서 약 등록으로 바로 이어준다.
/// 로그인 화면으로 되돌려 보내면 방금 만든 계정으로 다시 들어와야 한다.
class SignupDoneScreen extends StatelessWidget {
  final String name;

  const SignupDoneScreen({super.key, required this.name});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(26, 60, 26, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 96,
                        height: 96,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          color: AppColors.pointTint,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          TablerIcons.check,
                          size: 52,
                          color: AppColors.point,
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    Text(
                      '가입이 끝났어요',
                      textAlign: TextAlign.center,
                      style: AppText.screenTitle(size: 28),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '$name 님, 반갑습니다.\n이제 드시는 약만 넣으면 됩니다.',
                      textAlign: TextAlign.center,
                      style: AppText.body(
                        size: 19,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 0, 26, 30),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SeniorButton(
                    label: '약 등록 시작하기',
                    minHeight: 74,
                    fontSize: 24,
                    onPressed: () => context.go('/first-run'),
                  ),
                  const SizedBox(height: 10),
                  SeniorButton(
                    label: '나중에 할게요',
                    kind: SeniorButtonKind.secondary,
                    minHeight: 62,
                    fontSize: 20,
                    onPressed: () => context.go('/'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 보기 칸을 두 칸씩 놓되, 한 줄로 안 들어가는 보기는 한 줄을 다 쓴다.
///
/// 글자를 줄이지 않고 줄바꿈을 막는 길이다. 반쪽 칸에 글자가 들어가는지
/// 실제로 재 보고 정한다.
class _OptionFlow extends StatelessWidget {
  final List<String> options;

  /// [full]이면 한 줄을 다 쓰는 칸이다.
  final Widget Function(String option, bool full) builder;

  const _OptionFlow({required this.options, required this.builder});

  /// 이 글자가 [maxWidth] 안에 한 줄로 들어가는지.
  static bool _fits(
    String text,
    TextStyle style,
    double maxWidth,
    double scale,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      textScaler: TextScaler.linear(scale),
    )..layout();
    return painter.width <= maxWidth;
  }

  @override
  Widget build(BuildContext context) {
    final style = AppText.cardTitle(size: 19);
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 칸 안쪽 여백(12+12)과 테두리(2+2), 칸 사이 간격 10을 뺀 폭.
        final half = (constraints.maxWidth - 10) / 2 - 28;
        final rows = <Widget>[];
        var i = 0;
        while (i < options.length) {
          final current = options[i];
          final next = i + 1 < options.length ? options[i + 1] : null;
          final pairs =
              next != null &&
              _fits(current, style, half, scale) &&
              _fits(next, style, half, scale);
          rows.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: pairs
                      ? [
                          Expanded(child: builder(current, false)),
                          const SizedBox(width: 10),
                          Expanded(child: builder(next, false)),
                        ]
                      : [Expanded(child: builder(current, true))],
                ),
              ),
            ),
          );
          i += pairs ? 2 : 1;
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
    );
  }
}
