/// 화면 확인용 임시 통로. 보호자 계정 없이 보호자 화면만 열어 본다.
///
/// 확인이 끝나면 이 파일과 main.dart의 '/demo-guardian' 경로,
/// 로그인 화면의 임시 단추를 함께 지운다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/dashboard/presentation/screens/guardian_home_screen.dart';
import 'features/dashboard/presentation/screens/patient_data.dart';
import 'features/guardian/application/guardians_provider.dart';
import 'features/guardian/data/alert_repository.dart';
import 'features/profile/application/current_user_controller.dart';
import 'features/profile/domain/user_profile.dart';

/// 서버 없이 보호자 한 사람.
class _DemoUser extends CurrentUserController {
  @override
  Future<UserProfile?> build() async => const UserProfile(
    id: 'demo-guardian',
    name: '김지안',
    role: 'guardian',
    phone: '010-2345-6789',
  );
}

class _DemoAlerts implements AlertRepository {
  @override
  Future<List<AlertItem>?> fetch(String userId) async => const [
    AlertItem(
      type: 'miss',
      title: '약을 안 드셨어요',
      desc: '어머니가 저녁 약을 드시지 않았어요',
      time: '어제 저녁',
      tappable: false,
    ),
    AlertItem(
      type: 'done',
      title: '복약 완료',
      desc: '어머니가 점심 약을 드셨어요',
      time: '오늘 12:10',
      tappable: false,
    ),
    AlertItem(
      type: 'prescription',
      title: '새 처방전',
      desc: '약 3가지가 새로 등록됐어요',
      time: '어제',
      tappable: true,
    ),
    AlertItem(
      type: 'past',
      title: '심박수',
      desc: '일주일 동안 모두 정상이었어요',
      time: '3일 전',
      tappable: false,
    ),
  ];
}

const _patients = [
  CarePatient(
    linkId: 'demo-1',
    patientId: 'demo-1',
    name: '김복자',
    relation: '어머니',
    phone: '010-3921-4477',
    age: 68,
    takenCount: 2,
    totalCount: 3,
    nextDoseLabel: '저녁',
    slots: [
      CareSlot('아침', true),
      CareSlot('점심', true),
      CareSlot('저녁 6시', false),
    ],
    heartRate: 72,
    heartRateNormal: true,
    weekRate: 94,
    activities: [
      ActivityItem('점심 약을 드셨어요', '오늘 12:10'),
      ActivityItem('아침 약을 드셨어요', '오늘 08:05'),
    ],
  ),
  CarePatient(
    linkId: 'demo-2',
    patientId: 'demo-2',
    name: '김성호',
    relation: '아버지',
    takenCount: 3,
    totalCount: 3,
    slots: [CareSlot('아침', true), CareSlot('점심', true), CareSlot('저녁', true)],
    heartRate: 68,
    heartRateNormal: true,
    weekRate: 100,
  ),
  CarePatient(
    linkId: 'demo-3',
    patientId: 'demo-3',
    name: '박영자',
    relation: '장모님',
    takenCount: 1,
    totalCount: 2,
    nextDoseLabel: '점심',
    slots: [CareSlot('아침', true), CareSlot('점심', false)],
    heartRate: 75,
    heartRateNormal: true,
    weekRate: 88,
  ),
];

/// 가짜 어르신 셋으로 보호자 화면을 연다.
class DemoGuardianScreen extends StatelessWidget {
  const DemoGuardianScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        currentUserProvider.overrideWith(_DemoUser.new),
        careOverviewProvider.overrideWith(
          (ref) async => const CareOverview(patients: _patients),
        ),
      ],
      child: GuardianHomeScreen(alertsRepository: _DemoAlerts()),
    );
  }
}
