import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../features/auth/auth_flow.dart';
import '../features/auth/auth_session.dart';
import '../features/auth/credentials_screens.dart';
import '../features/auth/password_reset_screens.dart';
import '../features/auth/registration_consent_screen.dart';
import '../features/auth/restore_screen.dart';
import '../features/auth/verify_screen.dart';
import '../features/auth/welcome_screen.dart';
import '../features/catalog/catalog_sources_screen.dart';
import '../features/consent/consent_gate_controller.dart';
import '../features/consent/consent_gate_screen.dart';
import '../features/family/accept_invite_screen.dart';
import '../features/family/add_medication_route.dart';
import '../features/family/family_screen.dart';
import '../features/family/invite_create_screen.dart';
import '../features/family/managed_profile_screen.dart';
import '../features/family/relative_detail_screen.dart';
import '../features/history/history_screen.dart';
import '../features/medications/medication_edit_screen.dart';
import '../features/medications/medications_screen.dart';
import '../features/privacy/export_screen.dart';
import '../features/privacy/privacy_data_screen.dart';
import '../features/report/reports_screen.dart';
import '../features/schedule/schedule_editor_screen.dart';
import '../features/settings/change_password_screen.dart';
import '../features/settings/own_name_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/shell/home_shell.dart';
import '../features/shell/tab_pager.dart';
import '../features/today/today_screen.dart';
import '../theme/motion.dart';
import '../theme/page_transitions.dart';
import 'routes.dart';

export 'routes.dart';

/// The app router: onboarding, four tabs, and screens pushed above them.
///
/// The auth gate is [authRedirect] over [authSessionProvider] and
/// [consentRequiredProvider]; the router re-evaluates it whenever either
/// changes.
final routerProvider = Provider<GoRouter>((ref) {
  final sessionChanges = ValueNotifier<int>(0);
  ref.listen(authSessionProvider, (previous, next) => sessionChanges.value++);
  ref.listen(
    consentRequiredProvider,
    (previous, next) => sessionChanges.value++,
  );
  ref.listen(
    consentPendingProvider,
    (previous, next) => sessionChanges.value++,
  );
  final router = GoRouter(
    initialLocation: AppRoutes.today,
    refreshListenable: sessionChanges,
    redirect: (context, state) {
      final session = ref.read(authSessionProvider);
      // An unreadable keystore counts as signed out.
      final signedIn = session.hasError ? false : session.valueOrNull;
      final target = authRedirect(
        signedIn: signedIn,
        location: state.matchedLocation,
        consentRequired: ref.read(consentRequiredProvider),
        consentPending: ref.read(consentPendingProvider),
      );
      // The code screen needs the address of the request (a restored route
      // or a deep link has none): start from the address step.
      if (target == null &&
          state.matchedLocation == AppRoutes.resetPassword &&
          ref.read(authFlowProvider).email == null) {
        return AppRoutes.forgotPassword;
      }
      // The consent step needs the credentials of step 1 (a restored route
      // or a deep link has none): start from the form.
      if (target == null &&
          state.matchedLocation == AppRoutes.registerConsent &&
          !ref.read(authFlowProvider).credentialsHeld) {
        return AppRoutes.register;
      }
      return target;
    },
    routes: [
      GoRoute(
        path: AppRoutes.loading,
        pageBuilder: (context, state) =>
            _fadePage(context, state, const _LoadingScreen()),
      ),
      ..._authRoutes,
      GoRoute(
        path: AppRoutes.consentGate,
        pageBuilder: (context, state) =>
            _fadePage(context, state, const ConsentGateScreen()),
      ),
      StatefulShellRoute(
        // The shell replaces the loading or sign-in screen after a redirect:
        // it fades in, it is not pushed.
        pageBuilder: (context, state, navigationShell) => _fadePage(
          context,
          state,
          HomeShell(navigationShell: navigationShell),
        ),
        // The tabs turn like pages (docs/design/b2/README.md, "Motion").
        navigatorContainerBuilder: (context, navigationShell, children) =>
            TabPager(
          currentIndex: navigationShell.currentIndex,
          children: children,
        ),
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
      GoRoute(
        path: AppRoutes.reports,
        builder: (context, state) => const ReportsScreen(),
      ),
      GoRoute(
        path: AppRoutes.changePassword,
        builder: (context, state) => const ChangePasswordScreen(),
      ),
      GoRoute(
        path: AppRoutes.ownName,
        builder: (context, state) => const OwnNameScreen(),
      ),
      GoRoute(
        path: AppRoutes.privacyData,
        builder: (context, state) => const PrivacyDataScreen(),
      ),
      GoRoute(
        path: AppRoutes.dataExport,
        builder: (context, state) => const ExportScreen(),
      ),
      GoRoute(
        path: AppRoutes.catalogSources,
        builder: (context, state) => const CatalogSourcesScreen(),
      ),
    ],
  );
  ref.onDispose(() {
    router.dispose();
    sessionChanges.dispose();
  });
  return router;
});

/// A screen that replaces what was there and fades in: the loading screen,
/// the consent gate, the tab shell, welcome and sign-in (the targets of
/// redirects). Other screens slide (`PillPalPageTransitionsBuilder`). `base`,
/// or `fast` with reduced motion.
Page<void> _fadePage(BuildContext context, GoRouterState state, Widget child) {
  final duration = PillPalMotion.transition(context, PillPalMotion.base);
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: duration,
    reverseTransitionDuration: duration,
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        PillPalFadePageTransition(animation: animation, child: child),
  );
}

StatefulShellBranch _branch(String path, Widget screen) {
  return StatefulShellBranch(
    routes: [GoRoute(path: path, builder: (context, state) => screen)],
  );
}

final List<RouteBase> _authRoutes = [
  GoRoute(
    path: AppRoutes.welcome,
    pageBuilder: (context, state) =>
        _fadePage(context, state, const WelcomeScreen()),
    routes: [
      GoRoute(
        path: 'register',
        builder: (context, state) => const RegisterScreen(),
        routes: [
          GoRoute(
            path: 'consent',
            builder: (context, state) => const RegistrationConsentScreen(),
          ),
        ],
      ),
      GoRoute(
        path: 'verify',
        builder: (context, state) => const VerifyScreen(),
      ),
      GoRoute(
        path: 'login',
        pageBuilder: (context, state) {
          final extra = state.extra;
          return _fadePage(
            context,
            state,
            LoginScreen(args: extra is LoginRouteArgs ? extra : null),
          );
        },
      ),
      GoRoute(
        path: 'forgot',
        builder: (context, state) {
          final extra = state.extra;
          return ForgotPasswordScreen(email: extra is String ? extra : null);
        },
      ),
      GoRoute(
        path: 'reset',
        builder: (context, state) => const ResetPasswordScreen(),
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
      autoScan: wantsScan(state.uri),
    ),
  ),
];

final List<RouteBase> _detailRoutes = [
  ..._familyRoutes,
  GoRoute(
    path: AppRoutes.newMedication,
    builder: (context, state) =>
        MedicationEditScreen(autoScan: wantsScan(state.uri)),
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
