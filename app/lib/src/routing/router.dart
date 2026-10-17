import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/auth_session.dart';
import '../features/auth/credentials_screens.dart';
import '../features/auth/restore_screen.dart';
import '../features/auth/verify_screen.dart';
import '../features/auth/welcome_screen.dart';
import '../features/family/accept_invite_screen.dart';
import '../features/family/family_screen.dart';
import '../features/family/invite_create_screen.dart';
import '../features/family/managed_profile_screen.dart';
import '../features/family/relative_detail_screen.dart';
import '../features/history/history_screen.dart';
import '../features/medications/medication_edit_screen.dart';
import '../features/medications/medications_screen.dart';
import '../features/schedule/schedule_editor_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/shell/home_shell.dart';
import '../features/today/today_screen.dart';
import 'routes.dart';

export 'routes.dart';

/// The app router: onboarding, four tabs, and screens pushed above them.
///
/// The auth gate is [authRedirect] over [authSessionProvider]; the router
/// re-evaluates it whenever the session changes.
final routerProvider = Provider<GoRouter>((ref) {
  final sessionChanges = ValueNotifier<int>(0);
  ref.listen(authSessionProvider, (previous, next) => sessionChanges.value++);
  final router = GoRouter(
    initialLocation: AppRoutes.today,
    refreshListenable: sessionChanges,
    redirect: (context, state) {
      final session = ref.read(authSessionProvider);
      // An unreadable keystore counts as signed out.
      final signedIn = session.hasError ? false : session.valueOrNull;
      return authRedirect(
        signedIn: signedIn,
        location: state.matchedLocation,
      );
    },
    routes: [
      GoRoute(
        path: AppRoutes.loading,
        builder: (context, state) => const _LoadingScreen(),
      ),
      ..._authRoutes,
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HomeShell(navigationShell: navigationShell),
        branches: [
          _branch(AppRoutes.today, const TodayScreen()),
          _branch(AppRoutes.medications, const MedicationsScreen()),
          _branch(AppRoutes.family, const FamilyScreen()),
          _branch(AppRoutes.history, const HistoryScreen()),
        ],
      ),
      ..._detailRoutes,
      GoRoute(
        path: AppRoutes.settings,
        builder: (context, state) => const SettingsScreen(),
      ),
    ],
  );
  ref.onDispose(() {
    router.dispose();
    sessionChanges.dispose();
  });
  return router;
});

StatefulShellBranch _branch(String path, Widget screen) {
  return StatefulShellBranch(
    routes: [GoRoute(path: path, builder: (context, state) => screen)],
  );
}

final List<RouteBase> _authRoutes = [
  GoRoute(
    path: AppRoutes.welcome,
    builder: (context, state) => const WelcomeScreen(),
    routes: [
      GoRoute(
        path: 'register',
        builder: (context, state) => const RegisterScreen(),
      ),
      GoRoute(
        path: 'verify',
        builder: (context, state) => const VerifyScreen(),
      ),
      GoRoute(
        path: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: 'restore',
        builder: (context, state) => const RestoreScreen(),
      ),
    ],
  ),
];

/// Relatives: invites, links, managed profiles and the day view of a
/// profile (a relative's Today, Medications and History above the tabs).
final List<RouteBase> _familyRoutes = [
  GoRoute(
    path: AppRoutes.acceptInvite,
    builder: (context, state) => const AcceptInviteScreen(),
  ),
  GoRoute(
    path: AppRoutes.newManagedProfile,
    builder: (context, state) => const ManagedProfileScreen(),
  ),
  GoRoute(
    path: '/family/managed/:profileId',
    builder: (context, state) => ManagedProfileScreen(
      profileId: state.pathParameters['profileId'],
    ),
  ),
  GoRoute(
    path: '/family/invite/:profileId',
    builder: (context, state) => InviteCreateScreen(
      profileId: state.pathParameters['profileId'] ?? '',
    ),
  ),
  GoRoute(
    path: '/family/link/:linkId',
    builder: (context, state) => RelativeDetailScreen(
      linkId: state.pathParameters['linkId'] ?? '',
    ),
  ),
  GoRoute(
    path: '/profile/:profileId/today',
    builder: (context, state) => TodayScreen(
      profileId: state.pathParameters['profileId'],
    ),
  ),
  GoRoute(
    path: '/profile/:profileId/medications',
    builder: (context, state) => MedicationsScreen(
      profileId: state.pathParameters['profileId'],
    ),
  ),
  GoRoute(
    path: '/profile/:profileId/history',
    builder: (context, state) => HistoryScreen(
      profileId: state.pathParameters['profileId'],
    ),
  ),
  GoRoute(
    path: '/profile/:profileId/add-medication',
    builder: (context, state) => MedicationEditScreen(
      profileId: state.pathParameters['profileId'],
    ),
  ),
];

final List<RouteBase> _detailRoutes = [
  ..._familyRoutes,
  GoRoute(
    path: AppRoutes.newMedication,
    builder: (context, state) => const MedicationEditScreen(),
  ),
  GoRoute(
    path: '/medication/:medicationId',
    builder: (context, state) => MedicationEditScreen(
      medicationId: state.pathParameters['medicationId'],
    ),
    routes: [
      GoRoute(
        path: 'schedule/new',
        builder: (context, state) => ScheduleEditorScreen(
          medicationId: state.pathParameters['medicationId'] ?? '',
        ),
      ),
      GoRoute(
        path: 'schedule/:scheduleId',
        builder: (context, state) => ScheduleEditorScreen(
          medicationId: state.pathParameters['medicationId'] ?? '',
          scheduleId: state.pathParameters['scheduleId'],
        ),
      ),
    ],
  ),
];

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
