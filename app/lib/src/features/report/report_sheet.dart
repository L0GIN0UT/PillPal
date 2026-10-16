import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../common/choice_button.dart';
import '../common/error_snack_bar.dart';
import '../common/formatters.dart';
import '../common/info_note.dart';
import '../common/local_time.dart';
import 'report_model.dart';
import 'report_service.dart';

/// Opens the period picker of the doctor's report (mockup "History", PDF).
Future<void> showReportSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => const _ReportSheet(),
  );
}

class _ReportSheet extends ConsumerStatefulWidget {
  const _ReportSheet();

  @override
  ConsumerState<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<_ReportSheet> {
  int? _days = reportPresetDays[1];
  ReportRange? _custom;
  bool _busy = false;

  ReportRange? _range(LocalDate today) {
    final days = _days;
    return days == null ? _custom : lastDays(today, days);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final range = _range(ref.watch(todayDateProvider));
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.pdfReport, style: textTheme.titleLarge),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final days in reportPresetDays)
                  ChoiceButton(
                    key: ValueKey('report-days-$days'),
                    label: l10n.reportLastDays(days),
                    selected: _days == days,
                    onTap: () => setState(() => _days = days),
                  ),
                ChoiceButton(
                  key: const Key('report-custom'),
                  label: l10n.reportCustom,
                  selected: _days == null,
                  onTap: _pickCustom,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (range != null)
              Text(
                l10n.reportPeriod(
                  formatShortDate(range.first, locale),
                  formatShortDate(range.last, locale),
                ),
                key: const Key('report-range'),
                style: textTheme.bodyLarge,
              ),
            const SizedBox(height: 12),
            InfoNote(text: l10n.reportPrivacyNote),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('report-share'),
              onPressed: _busy || range == null ? null : () => _share(range),
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.ios_share),
              label: Text(l10n.reportShare),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickCustom() async {
    final today = ref.read(todayDateProvider);
    final current = _custom ?? lastDays(today, reportPresetDays[1]);
    DateTime asDate(LocalDate day) => DateTime(day.year, day.month, day.day);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: asDate(today.addDays(-maxReportDays * 2)),
      lastDate: asDate(today),
      initialDateRange: DateTimeRange(
        start: asDate(current.first),
        end: asDate(current.last),
      ),
    );
    if (picked == null || !mounted) {
      return;
    }
    LocalDate local(DateTime date) => LocalDate(date.year, date.month, date.day);
    var first = local(picked.start);
    final last = local(picked.end);
    // A longer period would make an unreadable day table: keep its end.
    if (rangeLength((first: first, last: last)) > maxReportDays) {
      first = last.addDays(1 - maxReportDays);
    }
    setState(() {
      _days = null;
      _custom = (first: first, last: last);
    });
  }

  Future<void> _share(ReportRange range) async {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(reportServiceProvider).share(range, l10n, locale);
      navigator.pop();
    } on Object {
      // Nothing is logged: the report is medical data.
      if (mounted) {
        setState(() => _busy = false);
        showErrorSnackBar(context);
      }
    }
  }
}
