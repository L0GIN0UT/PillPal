import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';

/// What the user chose when removing a medication or a schedule.
enum RemovalChoice {
  /// Stop from today; the history is kept (ADR 0003 §3).
  finish,

  /// Delete, history included.
  delete,
}

/// Asks how to remove something (ADR 0003 §3).
///
/// Without [hasHistory] it is a plain delete confirmation. With history it
/// offers "finish (history is kept)" when [canFinish] and "delete with
/// history". Null when cancelled.
Future<RemovalChoice?> askRemoval(
  BuildContext context, {
  required String title,
  required String plainBody,
  required String historyBody,
  required bool hasHistory,
  required bool canFinish,
}) {
  final l10n = AppLocalizations.of(context);
  return showDialog<RemovalChoice>(
    context: context,
    builder: (dialogContext) {
      void choose(RemovalChoice? choice) =>
          Navigator.of(dialogContext).pop(choice);
      return AlertDialog(
        title: Text(title),
        content: Text(hasHistory ? historyBody : plainBody),
        actions: [
          TextButton(
            key: const Key('removal-cancel'),
            onPressed: () => choose(null),
            child: Text(l10n.cancel),
          ),
          if (hasHistory && canFinish)
            TextButton(
              key: const Key('confirm-finish'),
              onPressed: () => choose(RemovalChoice.finish),
              child: Text(l10n.finishIntake),
            ),
          TextButton(
            key: const Key('confirm-delete'),
            onPressed: () => choose(RemovalChoice.delete),
            child: Text(hasHistory ? l10n.deleteWithHistory : l10n.delete),
          ),
        ],
      );
    },
  );
}
