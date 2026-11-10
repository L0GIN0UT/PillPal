import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/spacing.dart';

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
  return showDialog<UnknownGtinChoice>(
    context: context,
    builder: (context) => const _UnknownGtinDialog(),
  );
}

class _UnknownGtinDialog extends StatelessWidget {
  const _UnknownGtinDialog();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      key: const Key('scan-unknown'),
      title: Text(l10n.scanUnknownTitle),
      content: Text(l10n.scanUnknownBody),
      actionsOverflowDirection: VerticalDirection.down,
      actionsPadding: const EdgeInsets.fromLTRB(
        PillPalSpacing.lg,
        0,
        PillPalSpacing.lg,
        PillPalSpacing.md,
      ),
      actions: [
        FilledButton(
          key: const Key('scan-unknown-search'),
          onPressed: () => Navigator.of(context).pop(UnknownGtinChoice.search),
          child: Text(l10n.scanUnknownSearch),
        ),
        TextButton(
          key: const Key('scan-unknown-keep'),
          onPressed: () =>
              Navigator.of(context).pop(UnknownGtinChoice.keepNumber),
          child: Text(l10n.scanUnknownKeep),
        ),
        TextButton(
          key: const Key('scan-unknown-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
      ],
    );
  }
}
