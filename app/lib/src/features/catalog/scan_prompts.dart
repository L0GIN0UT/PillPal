import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../common/pillpal_dialog.dart';
import '../common/show_pillpal_dialog.dart';

/// What the person chose after a barcode the catalog does not know.
enum UnknownGtinChoice {
  /// Find the product by name and link it to the number.
  search,

  /// Keep only the number with the medication.
  keepNumber,
}

/// Asks what to do with a barcode the catalog does not know; null when the
/// person cancelled (nothing is changed).
Future<UnknownGtinChoice?> showUnknownGtinPrompt(BuildContext context) {
  return showPillPalDialog<UnknownGtinChoice>(
    context: context,
    builder: (context) => const _UnknownGtinDialog(),
  );
}

class _UnknownGtinDialog extends StatelessWidget {
  const _UnknownGtinDialog();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    void close([UnknownGtinChoice? choice]) =>
        Navigator.of(context).pop(choice);
    // Stacked full-width buttons of the dialog system (radius 28).
    return PillPalDialog(
      key: const Key('scan-unknown'),
      title: l10n.scanUnknownTitle,
      body: l10n.scanUnknownBody,
      choices: [
        DialogChoice(
          key: const Key('scan-unknown-search'),
          label: l10n.scanUnknownSearch,
          kind: DialogChoiceKind.primary,
          onPressed: () => close(UnknownGtinChoice.search),
        ),
        DialogChoice(
          key: const Key('scan-unknown-keep'),
          label: l10n.scanUnknownKeep,
          onPressed: () => close(UnknownGtinChoice.keepNumber),
        ),
        DialogChoice(
          key: const Key('scan-unknown-cancel'),
          label: l10n.cancel,
          onPressed: close,
        ),
      ],
    );
  }
}
