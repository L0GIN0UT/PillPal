import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import 'report_actions.dart';

/// What the person asks to do with a kept report.
enum ReportFileAction {
  /// Show it in a PDF viewer.
  open,

  /// Save a copy where the person chooses.
  save,

  /// Hand it to the share sheet.
  share,
}

/// How a [ReportFileAction] ended, for the person.
enum ReportOutcome {
  /// Done; nothing to say.
  done,

  /// A copy was saved: a short confirmation.
  saved,

  /// The person closed the system picker: silent.
  cancelled,

  /// No app can show a PDF: offer to save instead.
  noViewer,

  /// The previous action is still waiting for the system.
  busy,

  /// The file could not be processed.
  failed,
}

/// Runs [action] on [report] and maps every result of [ReportActions] to a
/// [ReportOutcome]. An exception is a `failed` outcome: nothing is logged,
/// the report is medical data (docs/adr/0019 §6).
Future<ReportOutcome> runReportFileAction(
  ReportActions actions,
  ReportFileAction action,
  StoredReport report,
) async {
  try {
    final result = switch (action) {
      ReportFileAction.open => await actions.open(report),
      ReportFileAction.save => await actions.save(report),
      ReportFileAction.share => await actions.share(report),
    };
    return switch (result) {
      ReportActionResult.done => action == ReportFileAction.save
          ? ReportOutcome.saved
          : ReportOutcome.done,
      ReportActionResult.cancelled => ReportOutcome.cancelled,
      ReportActionResult.noApp => ReportOutcome.noViewer,
      ReportActionResult.busy => ReportOutcome.busy,
    };
  } on Object {
    return ReportOutcome.failed;
  }
}

/// The sentence for [outcome]; null when it is silent.
String? reportOutcomeMessage(AppLocalizations l10n, ReportOutcome outcome) {
  return switch (outcome) {
    ReportOutcome.done || ReportOutcome.cancelled => null,
    ReportOutcome.saved => l10n.reportSaved,
    ReportOutcome.noViewer => l10n.reportNoViewer,
    ReportOutcome.busy => l10n.reportBusy,
    ReportOutcome.failed => l10n.reportFileError,
  };
}

/// Shows [outcome] in a snack bar of [messenger] (the list screen); with no
/// viewer it offers «Save» through [onSave]. Captured before the action so
/// that the context is not used after the await.
void showReportOutcome(
  ScaffoldMessengerState messenger,
  AppLocalizations l10n,
  ReportOutcome outcome, {
  required VoidCallback onSave,
}) {
  final message = reportOutcomeMessage(l10n, outcome);
  if (message == null) {
    return;
  }
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        key: const Key('report-outcome'),
        content: Text(message),
        action: outcome == ReportOutcome.noViewer
            ? SnackBarAction(label: l10n.save, onPressed: onSave)
            : null,
      ),
    );
}
