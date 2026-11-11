import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/confirm_dialog.dart';
import '../common/error_snack_bar.dart';
import '../common/gap.dart';
import '../common/list_row.dart';
import '../common/pillpal_card.dart';
import '../common/status_message.dart';
import '../family/profile_context.dart';
import 'report_actions.dart';
import 'report_file_action.dart';
import 'report_history.dart';
import 'report_labels.dart';
import 'report_model.dart';

/// «Мои отчёты» (board B2-MyReports): the PDF reports kept on this device,
/// newest first, each with a menu to open, save, share or delete it, and
/// «Удалить все» (docs/adr/0019). The list is made to agree with the disk when
/// the screen opens (`ReportHistory.reconcile`), so a row never opens a file
/// that is gone.
class ReportsScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(_reconcile());
  }

  Future<void> _reconcile() async {
    try {
      await ref.read(reportHistoryProvider).reconcile();
    } on Object {
      // Silent: the next start or sync run retries (nothing is logged).
    }
  }

  Future<void> _perform(ReportFileAction action, StoredReport report) async {
    // Everything the snack bar needs is read before the await.
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final actions = ref.read(reportActionsProvider);
    final outcome = await runReportFileAction(actions, action, report);
    if (!mounted) {
      return;
    }
    showReportOutcome(
      messenger,
      l10n,
      outcome,
      onSave: () => unawaited(_perform(ReportFileAction.save, report)),
    );
  }

  void _delete(StoredReport report) {
    runShowingErrors(
      context,
      ref.read(reportHistoryProvider).delete(report.id),
    );
  }

  void _onMenu(_RowAction choice, StoredReport report) {
    switch (choice) {
      case _RowAction.open:
        unawaited(_perform(ReportFileAction.open, report));
      case _RowAction.save:
        unawaited(_perform(ReportFileAction.save, report));
      case _RowAction.share:
        unawaited(_perform(ReportFileAction.share, report));
      case _RowAction.delete:
        _delete(report);
    }
  }

  Future<void> _deleteAll() async {
    final l10n = AppLocalizations.of(context);
    final history = ref.read(reportHistoryProvider);
    final confirmed = await confirmAction(
      context,
      title: l10n.reportsDeleteAllTitle,
      body: l10n.reportsDeleteAllBody,
      confirmLabel: l10n.reportsDeleteAll,
    );
    if (!confirmed || !mounted) {
      return;
    }
    runShowingErrors(context, history.deleteAll());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final reports = ref.watch(storedReportsProvider);
    final list = reports.valueOrNull;
    // From the compact text scale on the title and the button do not fit in
    // the bar: the button goes under the list (B2-README 9.7).
    final compact =
        MediaQuery.textScalerOf(context).scale(1) >= PillPalSizes.compactScale;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.reportsTitle),
        actions: [
          if (list != null && list.isNotEmpty && !compact)
            _deleteAllButton(context, l10n),
        ],
      ),
      body: reports.hasError
          ? Padding(
              padding: PillPalSpacing.screen,
              child: StatusMessage(
                icon: Icons.error_outline,
                text: l10n.errorGeneric,
              ),
            )
          : list == null
              ? const SizedBox.shrink()
              : _body(context, l10n, list, compact: compact),
    );
  }

  Widget _deleteAllButton(BuildContext context, AppLocalizations l10n) {
    return TextButton(
      key: const Key('reports-delete-all'),
      style: TextButton.styleFrom(foregroundColor: context.palette.danger),
      onPressed: () => unawaited(_deleteAll()),
      child: Text(l10n.reportsDeleteAll),
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    List<StoredReport> list, {
    required bool compact,
  }) {
    if (list.isEmpty) {
      return SingleChildScrollView(
        padding: PillPalSpacing.screen,
        child: Column(
          key: const Key('reports-empty'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StatusMessage(
              icon: Icons.description_outlined,
              text: l10n.reportsEmptyTitle,
            ),
            Text(
              l10n.reportsEmptyBody(storedReportRetention.inDays),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }
    final locale = Localizations.localeOf(context).toLanguageTag();
    final profiles = ref.watch(accessibleProfilesProvider).valueOrNull;
    return ListView(
      key: const Key('reports-list'),
      padding: PillPalSpacing.screen,
      children: [
        PillPalCard.rows(
          rows: [
            for (final report in list)
              _row(context, l10n, report, locale, profiles),
          ],
        ),
        if (compact) ...[
          const Gap.v(PillPalSpacing.md),
          _deleteAllButton(context, l10n),
        ],
      ],
    );
  }

  Widget _row(
    BuildContext context,
    AppLocalizations l10n,
    StoredReport report,
    String locale,
    List<ProfileAccess>? profiles,
  ) {
    final range = reportRangeLabel(l10n, report, locale);
    final meta = [
      reportProfileLabel(l10n, profiles, report.profileId),
      reportCreatedLabel(report, locale),
      reportSizeLabel(l10n, report.sizeBytes, locale),
    ].whereType<String>().join(' · ');
    return PillPalListRow(
      key: ValueKey('report-item-${report.id}'),
      title: range,
      subtitle: meta,
      leadingIcon: Icons.description_outlined,
      onTap: () => unawaited(_perform(ReportFileAction.open, report)),
      showChevron: false,
      trailing: _menu(context, l10n, report, range),
    );
  }

  Widget _menu(
    BuildContext context,
    AppLocalizations l10n,
    StoredReport report,
    String range,
  ) {
    final danger = context.palette.danger;
    return PopupMenuButton<_RowAction>(
      key: ValueKey('report-item-menu-${report.id}'),
      tooltip: l10n.reportMenuMore(range),
      style: IconButton.styleFrom(
        minimumSize: Size.square(context.metrics.touchTarget),
      ),
      onSelected: (choice) => _onMenu(choice, report),
      itemBuilder: (context) => [
        PopupMenuItem(
          key: const Key('report-menu-open'),
          value: _RowAction.open,
          child: Text(l10n.reportOpen),
        ),
        PopupMenuItem(
          key: const Key('report-menu-save'),
          value: _RowAction.save,
          child: Text(l10n.save),
        ),
        PopupMenuItem(
          key: const Key('report-menu-share'),
          value: _RowAction.share,
          child: Text(l10n.reportShare),
        ),
        PopupMenuItem(
          key: const Key('report-menu-delete'),
          value: _RowAction.delete,
          child: Text(l10n.delete, style: TextStyle(color: danger)),
        ),
      ],
    );
  }
}

enum _RowAction { open, save, share, delete }
