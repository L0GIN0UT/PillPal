import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../shell/empty_state.dart';

/// Relatives. Implemented in Phase 3 (TZ §2.5).
class FamilyScreen extends StatelessWidget {
  /// Creates the screen.
  const FamilyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.familyTitle)),
      body: EmptyState(
        icon: Icons.people_outline,
        message: l10n.familyComingSoon,
      ),
    );
  }
}
