import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/family/family_screen.dart';
import '../features/history/history_screen.dart';
import '../features/medications/medications_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/shell/home_shell.dart';
import '../features/today/today_screen.dart';

/// Route paths.
abstract final class AppRoutes {
  /// Today's doses (start screen).
  static const String today = '/today';

  /// Medication list.
  static const String medications = '/medications';

  /// Relatives (Phase 3).
  static const String family = '/family';

  /// History and reports.
  static const String history = '/history';

  /// App settings.
  static const String settings = '/settings';
}

/// The app router: four tabs plus pushed screens.
final routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: AppRoutes.today,
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HomeShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.today,
                builder: (context, state) => const TodayScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.medications,
                builder: (context, state) => const MedicationsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.family,
                builder: (context, state) => const FamilyScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.history,
                builder: (context, state) => const HistoryScreen(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.settings,
        builder: (context, state) => const SettingsScreen(),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
