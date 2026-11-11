import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/spacing.dart';
import '../common/choice_group.dart';
import '../common/error_snack_bar.dart';
import '../common/formatters.dart';
import '../common/gap.dart';
import '../common/local_time.dart';
import '../common/pillpal_banner.dart';
import '../common/pillpal_check_tile.dart';
import '../common/sheet_scaffold.dart';
import '../family/family_providers.dart';
import '../family/profile_context.dart';
import '../history/history_providers.dart';
import 'report_model.dart';
import 'report_service.dart';

/// Opens the period picker of the doctor's report (mockup "History", PDF).
///
/// The report is of [profileId] (null: the user's own profile). For a
/// relative it is made from what they share with the user.
Future<void> showReportSheet(BuildContext context, {String? profileId}) {
  return showPillPalSheet<void>(
    context,
    (context) => _ReportSheet(profileId: profileId),
  );
}

class _ReportSheet extends ConsumerStatefulWidget {
  const _ReportSheet({required this.profileId});

  final String? profileId;

  @override
  ConsumerState<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<_ReportSheet> {
  int? _days = reportPresetDays[1];
  ReportRange? _custom;
  bool _busy = false;
  bool _includeHidden = true;

  ReportRange? _range(LocalDate today) {
    final days = _days;
    return days == null ? _custom : lastDays(today, days);
  }

  /// Whether the account sees everything of the profile. Fail closed: while
  /// the role of another profile is unknown the report counts as a
  /// relative's (nothing hidden to leave out, the cautious note).
  bool _fullAccess(ProfileAccess? access) => widget.profileId == null
      ? access == null || access.hasFullAccess
      : access != null && access.hasFullAccess;

  String _note(AppLocalizations l10n, ProfileAccess? access) {
    if (!_fullAccess(access)) {
      return l10n.reportRelativeNote;
    }
    return access == null || access.isOwnSelf
        ? l10n.reportPrivacyNote
        : l10n.reportFullAccessNote;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final access =
        ref.watch(profileAccessProvider(widget.profileId)).valueOrNull;
    // Another person's profile reads its days in its own zone (D4).
    final today = localDateOf(
      ref.watch(nowProvider),
      ref.watch(historyZoneProvider(widget.profileId)),
    );
    final range = _range(today);
    return SheetScaffold(
      title: l10n.pdfReport,
      primaryAction: _shareButton(l10n, range),
      children: [
        Text(l10n.reportIntro, style: textTheme.bodyMedium),
        const Gap.v(PillPalSpacing.lg),
        Text(l10n.reportPeriodLabel, style: textTheme.titleSmall),
        const Gap.v(PillPalSpacing.sm),
        _periodChoices(l10n),
        const Gap.v(PillPalSpacing.md),
        if (range != null) _rangeText(context, range),
        // Projected profiles have no hidden medications to leave out.
        if (_fullAccess(access))
          PillPalCheckTile(
            tileKey: const Key('report-include-hidden'),
            value: _includeHidden,
            title: l10n.reportIncludeHidden,
            subtitle: l10n.reportIncludeHiddenHint,
            onChanged: (value) => setState(() => _includeHidden = value),
          ),
        const Gap.v(PillPalSpacing.md),
        PillPalBanner(
          icon: Icons.lock_outline,
          body: _note(l10n, access),
        ),
        ..._limitNote(l10n, textTheme),
      ],
    );
  }

  /// The presets and "custom" (the `null` option): custom opens the range
  /// picker instead of selecting at once.
  Widget _periodChoices(AppLocalizations l10n) {
    return ChoiceGroup<int?>(
      options: {
        for (final days in reportPresetDays) days: l10n.reportLastDays(days),
        null: l10n.reportCustom,
      },
      selected: _days,
      keyOf: (days) => days == null
          ? const Key('report-custom')
          : ValueKey('report-days-$days'),
      onSelected: _onPeriodSelected,
    );
  }

  /// A preset selects at once; "custom" (`null`) asks for a range first and
  /// keeps the current period when the picker is cancelled.
  void _onPeriodSelected(int? days) {
    if (days == null) {
      unawaited(_pickCustom());
    } else {
      setState(() => _days = days);
    }
  }

  Widget _rangeText(BuildContext context, ReportRange range) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Text(
      l10n.reportPeriod(
        formatShortDate(range.first, locale),
        formatShortDate(range.last, locale),
      ),
      key: const Key('report-range'),
      style: Theme.of(context).textTheme.bodySmall,
    );
  }

  List<Widget> _limitNote(AppLocalizations l10n, TextTheme textTheme) {
    final limit = ref.watch(accountFeaturesProvider).valueOrNull;
    final reports = limit?.pdfReportsLimit;
    if (limit == null || !limit.softLimitsEnabled || reports == null) {
      return const [];
    }
    return [
      const Gap.v(PillPalSpacing.sm),
      Text(
        l10n.reportLimitNote(reports),
        key: const Key('report-limit-note'),
        style: textTheme.bodySmall,
      ),
    ];
  }

  Widget _shareButton(AppLocalizations l10n, ReportRange? range) {
    return FilledButton.icon(
      key: const Key('report-share'),
      onPressed: _busy || range == null ? null : () => _share(range),
      icon: _busy
          ? const SizedBox.square(
              dimension: PillPalSizes.iconInline,
              child: CircularProgressIndicator(
                strokeWidth: PillPalSizes.outline,
              ),
            )
          : const Icon(Icons.ios_share),
      label: Text(l10n.reportShare),
    );
  }

  Future<void> _pickCustom() async {
    final today = localDateOf(
      ref.read(nowProvider),
      ref.read(historyZoneProvider(widget.profileId)),
    );
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
    LocalDate local(DateTime date) =>
        LocalDate(date.year, date.month, date.day);
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
      await ref.read(reportServiceProvider).share(
            range,
            l10n,
            locale,
            profileId: widget.profileId,
            includeHidden: _includeHidden,
          );
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
