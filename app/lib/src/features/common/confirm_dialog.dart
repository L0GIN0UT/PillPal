import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';

/// Asks the user to confirm something that cannot be taken back lightly.
/// True when [confirmLabel] was tapped; keys: `confirm-yes` and
/// `confirm-no`.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
}) async {
  final l10n = AppLocalizations.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Text(body)),
      actions: [
        TextButton(
          key: const Key('confirm-no'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.cancel),
        ),
        TextButton(
          key: const Key('confirm-yes'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
