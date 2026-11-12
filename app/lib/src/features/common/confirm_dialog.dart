import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import 'pillpal_dialog.dart';
import 'show_pillpal_dialog.dart';

/// Asks the user to confirm something that cannot be taken back lightly.
/// True when [confirmLabel] was tapped; keys: `confirm-yes` and
/// `confirm-no`.
///
/// A [destructive] dialog (the default: every caller deletes, leaves or
/// revokes) shows the danger icon disc and a `danger` confirm button, which
/// comes first; [consequences] are listed under the [body].
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  bool destructive = true,
  List<String> consequences = const [],
}) async {
  final l10n = AppLocalizations.of(context);
  final confirmed = await showPillPalDialog<bool>(
    context: context,
    builder: (dialogContext) => PillPalDialog(
      title: title,
      body: body,
      destructive: destructive,
      consequences: consequences,
      choices: [
        DialogChoice(
          key: const Key('confirm-yes'),
          label: confirmLabel,
          kind: destructive
              ? DialogChoiceKind.destructive
              : DialogChoiceKind.primary,
          onPressed: () => Navigator.of(dialogContext).pop(true),
        ),
        DialogChoice(
          key: const Key('confirm-no'),
          label: l10n.cancel,
          onPressed: () => Navigator.of(dialogContext).pop(false),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
