import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import 'pillpal_dialog.dart';

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
      return PillPalDialog(
        title: title,
        body: hasHistory ? historyBody : plainBody,
        destructive: true,
        // The destructive choice first; finishing keeps the history.
        choices: [
          DialogChoice(
            key: const Key('confirm-delete'),
            label: hasHistory ? l10n.deleteWithHistory : l10n.delete,
            kind: DialogChoiceKind.destructive,
            onPressed: () => choose(RemovalChoice.delete),
          ),
          if (hasHistory && canFinish)
            DialogChoice(
              key: const Key('confirm-finish'),
              label: l10n.finishIntake,
              onPressed: () => choose(RemovalChoice.finish),
            ),
          DialogChoice(
            key: const Key('removal-cancel'),
            label: l10n.cancel,
            onPressed: () => choose(null),
          ),
        ],
      );
    },
  );
}
