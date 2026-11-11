import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/banner_tone.dart';
import '../common/gap.dart';
import '../common/pillpal_banner.dart';
import '../common/pillpal_card.dart';
import '../common/sheet_scaffold.dart';
import '../common/stacked_buttons.dart';
import '../family/profile_context.dart';
import 'report_actions.dart';
import 'report_file_action.dart';
import 'report_history.dart';
import 'report_labels.dart';

/// The «Отчёт готов» state of the report sheet (board B2-ReportReady): what
/// was made, then «Открыть», «Сохранить» and «Поделиться», the note that a
/// saved or sent file is outside the app's control, and the way to «Мои
/// отчёты».
///
/// The sheet covers the screen's snack bars, so the result of an action is
/// told here, in a banner of the sheet (`report-notice`), with «Сохранить»
/// when no app can show a PDF.
class ReportReadyView extends ConsumerStatefulWidget {
  /// Creates the state for [report].
  const ReportReadyView({required this.report, super.key});

  /// The report just made.
  final StoredReport report;

  @override
  ConsumerState<ReportReadyView> createState() => _ReportReadyViewState();
}

class _ReportReadyViewState extends ConsumerState<ReportReadyView> {
  bool _busy = false;
  ReportOutcome? _outcome;
  ReportFileAction? _active;

  Future<void> _run(ReportFileAction action) async {
    setState(() {
      _busy = true;
      _active = action;
      _outcome = null;
    });
    final outcome = await runReportFileAction(
      ref.read(reportActionsProvider),
      action,
      widget.report,
    );
    if (mounted) {
      setState(() {
        _busy = false;
        _active = null;
        _outcome = outcome;
      });
    }
  }

  void _openHistory() {
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    unawaited(router.push(AppRoutes.reports));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final count = ref.watch(storedReportsProvider).valueOrNull?.length ?? 1;
    return SheetScaffold(
      title: l10n.reportReadyTitle,
      titleKey: const Key('report-ready-title'),
      liveTitle: true,
      children: [
        _summary(context, l10n),
        // Above the buttons: at a large text scale the sheet scrolls, and the
        // result must not hide below them.
        ..._notice(l10n),
        const Gap.v(PillPalSpacing.lg),
        StackedButtons(
          children: [
            FilledButton.icon(
              key: const Key('report-open'),
              onPressed:
                  _busy ? null : () => unawaited(_run(ReportFileAction.open)),
              icon: _icon(ReportFileAction.open, Icons.open_in_new),
              label: Text(l10n.reportOpen),
            ),
            OutlinedButton.icon(
              key: const Key('report-save'),
              onPressed:
                  _busy ? null : () => unawaited(_run(ReportFileAction.save)),
              icon: _icon(ReportFileAction.save, Icons.download_outlined),
              label: Text(l10n.save),
            ),
            OutlinedButton.icon(
              key: const Key('report-share'),
              onPressed:
                  _busy ? null : () => unawaited(_run(ReportFileAction.share)),
              icon: _icon(ReportFileAction.share, Icons.ios_share),
              label: Text(l10n.reportShare),
            ),
          ],
        ),
        const Gap.v(PillPalSpacing.lg),
        PillPalBanner(
          key: const Key('report-leaves-control'),
          tone: BannerTone.info,
          icon: Icons.info_outline,
          body: l10n.reportLeavesControl,
        ),
        const Gap.v(PillPalSpacing.sm),
        Center(
          child: TextButton(
            key: const Key('report-history'),
            onPressed: _busy ? null : _openHistory,
            child: Text(l10n.reportMyReports(count)),
          ),
        ),
      ],
    );
  }

  /// The icon of a button; a spinner while its action waits for the system.
  Widget _icon(ReportFileAction action, IconData icon) {
    if (_active != action) {
      return Icon(icon);
    }
    return const SizedBox.square(
      dimension: PillPalSizes.iconInline,
      child: CircularProgressIndicator(strokeWidth: PillPalSizes.outline),
    );
  }

  Widget _summary(BuildContext context, AppLocalizations l10n) {
    final locale = Localizations.localeOf(context).toLanguageTag();
    final textTheme = Theme.of(context).textTheme;
    final profiles = ref.watch(accessibleProfilesProvider).valueOrNull;
    final meta = joinReportMeta([
      reportProfileLabel(l10n, profiles, widget.report.profileId),
      l10n.reportFormatPdf,
      reportSizeLabel(l10n, widget.report.sizeBytes, locale),
    ]);
    return PillPalCard(
      key: const Key('report-summary'),
      child: Row(
        children: [
          DecoratedBox(
            decoration: ShapeDecoration(
              color: context.palette.raised,
              shape: const CircleBorder(),
            ),
            child: const SizedBox.square(
              dimension: PillPalSizes.avatarSm,
              child: ExcludeSemantics(
                child: Icon(
                  Icons.description_outlined,
                  size: PillPalSizes.iconInline,
                ),
              ),
            ),
          ),
          const Gap.h(PillPalSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reportRangeLabel(l10n, widget.report, locale),
                  style: textTheme.rowTitleStrong,
                ),
                Text(meta, style: textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _notice(AppLocalizations l10n) {
    final outcome = _outcome;
    final message =
        outcome == null ? null : reportOutcomeMessage(l10n, outcome);
    if (outcome == null || message == null) {
      return const [];
    }
    final failed =
        outcome == ReportOutcome.failed || outcome == ReportOutcome.busy;
    return [
      const Gap.v(PillPalSpacing.lg),
      PillPalBanner(
        key: const Key('report-notice'),
        tone: failed ? BannerTone.danger : BannerTone.soft,
        icon:
            outcome == ReportOutcome.saved ? Icons.check_circle_outline : null,
        body: message,
        liveRegion: true,
        actions: [
          if (outcome == ReportOutcome.noViewer)
            TextButton(
              key: const Key('report-notice-save'),
              onPressed: () => unawaited(_run(ReportFileAction.save)),
              child: Text(l10n.save),
            ),
        ],
      ),
    ];
  }
}
