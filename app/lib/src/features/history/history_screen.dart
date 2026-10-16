import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../shell/empty_state.dart';

/// Intake history and reports. Content arrives in milestone 2.2.
class HistoryScreen extends StatelessWidget {
  /// Creates the screen.
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.historyTitle)),
      body: EmptyState(
        icon: Icons.calendar_month_outlined,
        message: l10n.historyEmpty,
      ),
    );
  }
}
