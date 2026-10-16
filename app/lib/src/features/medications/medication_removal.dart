import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../common/error_snack_bar.dart';
import '../common/removal_dialog.dart';
import '../doses/scheduled_doses.dart';
import 'medication_providers.dart';

/// Asks how to remove medication [id] and does it, then leaves the screen
/// (ADR 0003 §3): with history the user may finish it (kept, archived) or
/// delete it with its history; without history it is a plain delete.
Future<void> removeMedication(
  BuildContext context,
  WidgetRef ref,
  String id,
) async {
  final l10n = AppLocalizations.of(context);
  final service = ref.read(medicationServiceProvider);
  // The form is replaced once the medication disappears from the stream, so
  // the router is captured before any write.
  final router = GoRouter.of(context);
  try {
    final rules = [for (final s in await service.schedulesOf(id)) s.rule];
    final today = await service.todayFor(id);
    if (!context.mounted) {
      return;
    }
    final choice = await askRemoval(
      context,
      title: l10n.deleteMedicationTitle,
      plainBody: l10n.deleteMedicationBody,
      historyBody: l10n.removeMedicationBody,
      hasHistory: rules.any((rule) => hasHistoryBefore(rule, today)),
      canFinish: rules.any(
        (rule) => hasHistoryBefore(rule, today) && !hasEndedBy(rule, today),
      ),
    );
    switch (choice) {
      case null:
        return;
      case RemovalChoice.finish:
        await service.finish(id);
      case RemovalChoice.delete:
        await service.delete(id);
    }
    router.pop();
  } on Object {
    if (context.mounted) {
      showErrorSnackBar(context);
    }
  }
}
