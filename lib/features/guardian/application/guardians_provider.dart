import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../dashboard/presentation/screens/patient_data.dart';
import '../data/guardian_repository.dart';

/// 어르신 쪽 — 내게 등록된 보호자(수락 대기 포함). 바뀌면 invalidate 해서 다시 읽는다.
final guardiansProvider = FutureProvider<List<GuardianContact>>(
  (ref) => GuardianRepository().fetchAll(),
);

/// 보호자 쪽 — 돌보는 어르신들의 오늘 현황과 수락을 기다리는 요청.
final careOverviewProvider = FutureProvider<CareOverview>(
  (ref) => GuardianRepository().fetchCareOverview(),
);
