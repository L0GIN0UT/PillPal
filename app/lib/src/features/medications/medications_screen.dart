import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../shell/empty_state.dart';

/// Medication list. Content arrives in milestone 2.2.
class MedicationsScreen extends StatelessWidget {
  /// Creates the screen.
  const MedicationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.medicationsTitle)),
      body: EmptyState(
        icon: Icons.medication_liquid_outlined,
        message: l10n.medicationsEmpty,
      ),
    );
  }
}
