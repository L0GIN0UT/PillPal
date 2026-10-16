import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../routing/router.dart';
import '../shell/empty_state.dart';

/// Today's doses. Content arrives in milestone 2.2.
class TodayScreen extends StatelessWidget {
  /// Creates the screen.
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.todayTitle),
        actions: [
          IconButton(
            tooltip: l10n.settingsTitle,
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push(AppRoutes.settings),
          ),
        ],
      ),
      body: EmptyState(
        icon: Icons.medication_outlined,
        message: l10n.todayEmpty,
        action: FilledButton.icon(
          onPressed: () => context.go(AppRoutes.medications),
          icon: const Icon(Icons.add),
          label: Text(l10n.addMedication),
        ),
      ),
    );
  }
}
