import 'dart:convert';

import 'package:alkong_yakong/core/network/api_client.dart';
import 'package:alkong_yakong/core/providers/user_role.dart';
import 'package:alkong_yakong/core/session/auth_session.dart';
import 'package:alkong_yakong/core/session/mvp_session.dart';
import 'package:alkong_yakong/features/auth/presentation/screens/login_screen.dart';
import 'package:alkong_yakong/features/prescription/presentation/screens/prescription_screen.dart';
import 'package:alkong_yakong/features/profile/application/session_actions.dart';
import 'package:alkong_yakong/features/profile/data/user_repository.dart';
import 'package:alkong_yakong/features/profile/domain/user_profile.dart';
import 'package:alkong_yakong/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AuthSession.load();
    AuthSession.isLoggedIn = false;
    AuthSession.role = 'patient';
    MvpSession.userId = '';
    MvpSession.isPregnant = null;
  });

  testWidgets('unauthenticated users cannot navigate to protected screens', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: AlkongYakongApp()));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);

    final router = GoRouter.of(tester.element(find.byType(LoginScreen)));
    router.go('/biosignal');
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
    router.go('/');
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);

    router.go('/prescription');
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(PrescriptionScreen), findsNothing);
  });

  test(
    'login repository uses the real endpoint and returned identity',
    () async {
      var calls = 0;
      final repository = UserRepository(
        apiClient: ApiClient(
          client: MockClient((request) async {
            calls++;
            expect(request.method, 'POST');
            expect(request.url.path, '/api/v1/users/login');
            expect(jsonDecode(request.body), {
              'phone': '01012345678',
              'password': 'secret123',
            });
            return http.Response(
              jsonEncode({
                'id': 'server-guardian-uuid',
                'name': '검증용 사용자',
                'role': 'guardian',
                'is_pregnant': false,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      );

      final user = await repository.login(
        phone: '01012345678',
        password: 'secret123',
      );
      expect(calls, 1);
      expect(user.id, 'server-guardian-uuid');
      expect(user.isGuardian, isTrue);
    },
  );

  test('an incomplete login response cannot create a user session', () async {
    final repository = UserRepository(
      apiClient: ApiClient(
        client: MockClient(
          (request) async => http.Response(
            jsonEncode({'id': 'server-uuid'}),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      ),
    );
    await expectLater(
      repository.login(phone: '01012345678', password: 'secret123'),
      throwsA(isA<ApiException>()),
    );
    expect(AuthSession.isLoggedIn, isFalse);
  });

  test(
    'app restart restores only a matching server UUID and server role',
    () async {
      SharedPreferences.setMockInitialValues({
        'isLoggedIn': true,
        'userId': 'saved-user-uuid',
        'role': 'patient',
      });
      var calls = 0;
      final repository = UserRepository(
        apiClient: ApiClient(
          client: MockClient((request) async {
            calls++;
            expect(request.method, 'GET');
            expect(request.url.path, '/api/v1/users/saved-user-uuid');
            return http.Response(
              jsonEncode({
                'id': 'saved-user-uuid',
                'name': '검증용 보호자',
                'role': 'guardian',
                'is_pregnant': false,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      );

      final user = await restorePersistedSession(repository);
      expect(calls, 1);
      expect(user?.id, 'saved-user-uuid');
      expect(user?.role, 'guardian');
      expect(AuthSession.isLoggedIn, isTrue);
      expect(AuthSession.role, 'guardian');
      expect(MvpSession.userId, 'saved-user-uuid');
    },
  );

  test(
    'app restart rejects a mismatched or unavailable server identity',
    () async {
      SharedPreferences.setMockInitialValues({
        'isLoggedIn': true,
        'userId': 'saved-user-uuid',
        'role': 'guardian',
      });
      final mismatch = UserRepository(
        apiClient: ApiClient(
          client: MockClient(
            (request) async => http.Response(
              jsonEncode({
                'id': 'different-user-uuid',
                'name': '다른 사용자',
                'role': 'guardian',
              }),
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        ),
      );
      expect(await restorePersistedSession(mismatch), isNull);
      expect(AuthSession.isLoggedIn, isFalse);
      expect(MvpSession.userId, isEmpty);

      final unavailable = UserRepository(
        apiClient: ApiClient(
          client: MockClient(
            (request) async => http.Response(
              '{"detail":"not found"}',
              404,
              headers: {'content-type': 'application/json'},
            ),
          ),
        ),
      );
      expect(await restorePersistedSession(unavailable), isNull);
      expect(AuthSession.isLoggedIn, isFalse);
      expect(MvpSession.userId, isEmpty);
    },
  );

  testWidgets('a new server user replaces the previous role and identity', (
    tester,
  ) async {
    late WidgetRef actionRef;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, child) {
              actionRef = ref;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Consumer)),
    );
    await startSession(
      actionRef,
      const UserProfile(
        id: 'server-patient-uuid',
        name: '첫 사용자',
        role: 'patient',
        isPregnant: true,
      ),
    );
    expect(AuthSession.isLoggedIn, isTrue);
    expect(MvpSession.userId, 'server-patient-uuid');
    expect(MvpSession.isPregnant, isTrue);
    expect(container.read(userRoleProvider), UserRole.patient);

    await startSession(
      actionRef,
      const UserProfile(
        id: 'server-guardian-uuid',
        name: '다음 사용자',
        role: 'guardian',
        isPregnant: false,
      ),
    );
    expect(MvpSession.userId, 'server-guardian-uuid');
    expect(MvpSession.isPregnant, isFalse);
    expect(container.read(userRoleProvider), UserRole.guardian);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('userId'), 'server-guardian-uuid');

    await endSession(actionRef);
    expect(AuthSession.isLoggedIn, isFalse);
    expect(MvpSession.userId, isEmpty);
    expect(prefs.getString('userId'), isNull);
  });

  testWidgets('placeholder identity cannot start a session', (tester) async {
    late WidgetRef actionRef;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, child) {
              actionRef = ref;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await expectLater(
      startSession(
        actionRef,
        const UserProfile(id: 'mvp-user', name: '가짜 사용자'),
      ),
      throwsStateError,
    );
    expect(AuthSession.isLoggedIn, isFalse);
    expect(MvpSession.userId, isEmpty);
  });
}
