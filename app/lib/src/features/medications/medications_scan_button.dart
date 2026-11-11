import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../common/clamped_text.dart';

/// «Сканировать» on the medication list: opens the add form with the barcode
/// scanner up (docs/ui-pass-plan.md D4). An extended button in the «Забота»
/// shape (stadium, 56 high, 64 in senior mode, from the theme), so the label
/// says what it does; the round «+» in the header stays the plain way in.
/// The label stops growing at x1.3 of text (B2-README section 9.9).
class MedicationsScanButton extends StatelessWidget {
  /// Creates the button.
  const MedicationsScanButton({required this.onPressed, super.key});

  /// Called when the button is tapped.
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return FloatingActionButton.extended(
      // No hero: the list may be pushed over another screen with a button.
      heroTag: null,
      onPressed: onPressed,
      icon: const Icon(Icons.qr_code_scanner),
      label: ClampedText(
        l10n.medicationsScan,
        maxScale: PillPalSizes.fabLabelMaxScale,
      ),
    );
  }
}
