import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';

/// "Scan" on the medication list: opens the add form with the barcode
/// scanner up (docs/ui-pass-plan.md D4). An extended button, so the label
/// says what it does; "+" in the app bar stays the plain way in.
class MedicationsScanButton extends StatelessWidget {
  /// Creates the button.
  const MedicationsScanButton({required this.onPressed, super.key});

  /// Called when the button is tapped.
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Senior mode asks for bigger targets than the default 56 of a FAB.
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: context.metrics.touchTarget),
      child: FloatingActionButton.extended(
        // No hero: the list may be pushed over another screen with a button.
        heroTag: null,
        onPressed: onPressed,
        icon: const Icon(Icons.qr_code_scanner),
        label: Text(l10n.medicationsScan),
      ),
    );
  }
}
