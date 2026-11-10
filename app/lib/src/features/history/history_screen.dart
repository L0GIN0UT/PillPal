import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/spacing.dart';
import '../common/compact_text.dart';
import '../common/formatters.dart';
import '../common/pillpal_icon_button.dart';
import '../common/gap.dart';
import '../common/local_time.dart';
import '../family/archived_profile_banner.dart';
import '../family/profile_context.dart';
import '../family/profile_note.dart';
import '../family/profile_switcher.dart';
import '../report/report_sheet.dart';
import 'day_details.dart';
import 'history_model.dart';
import 'history_providers.dart';
import 'month_calendar.dart';
import 'scroll_into_view.dart';

/// Month calendar, adherence %, streak, day details and the doctor's PDF
/// report (mockup "History"); the ad slot is Phase 5.
///
/// As a tab it shows the profile chosen with the switcher; with a
/// [profileId] it is that profile's history, pushed above the tabs.
class HistoryScreen extends ConsumerWidget {
  /// Creates the screen.
  const HistoryScreen({this.profileId, super.key});

  /// The profile of a pushed screen; null for the tab.
  final String? profileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final shown = profileId ?? ref.watch(selectedProfileIdProvider);
    final access = ref.watch(profileAccessProvider(shown)).valueOrNull;
    final other = access != null && !access.isOwnSelf ? access : null;
    final history = ref.watch(monthHistoryProvider(shown));
    final streak = ref.watch(adherenceStreakProvider(shown)).valueOrNull;
    final selected = ref.watch(historySelectedDayProvider);
    final month = ref.read(historyMonthProvider.notifier);
    final zone = ref.watch(historyZoneProvider(shown));
    return Scaffold(
      appBar: AppBar(
        title: Text(_title(l10n, other)),
        actions: [
          // B-History: the report sits in the header, not under the list.
          PillPalIconButton(
            key: const Key('history-pdf'),
            tooltip: l10n.pdfReport,
            icon: Icons.description_outlined,
            onPressed: () => showReportSheet(context, profileId: shown),
          ),
        ],
      ),
      body: history.when(
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(child: Text(l10n.errorGeneric)),
        data: (data) {
          final day = selected == null ? null : data.day(selected);
          return ListView(
            padding: PillPalSpacing.screen,
            children: [
              if (profileId == null) const ProfileSwitcher(),
              if (access != null && access.archived)
                ArchivedProfileBanner(access: access),
              if (other != null) ProfileNote(access: other),
              MonthCalendar(
                history: data,
                summary: _StatsRow(history: data, streak: streak),
                selected: selected,
                onSelect: (date) => ref
                    .read(historySelectedDayProvider.notifier)
                    .select(date == selected ? null : date),
                onPrevious: () => month.show(previousMonthStart(data.month)),
                onNext: () => month.show(nextMonthStart(data.month)),
              ),
              if (day != null) ...[
                const Gap.v(PillPalSpacing.md),
                ScrollIntoView(
                  key: ValueKey(day.date),
                  child: DayDetails(day: day, zone: zone),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  String _title(AppLocalizations l10n, ProfileAccess? other) => other == null
      ? l10n.historyTitle
      : l10n.historyOf(other.profile.displayName);
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.history, required this.streak});

  final MonthHistory history;
  final int? streak;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final percent = history.adherencePercent;
    final days = streak ?? 0;
    final adherence = _Stat(
      key: const Key('history-percent'),
      value: percent == null ? '—' : '$percent%',
      label: l10n.adherenceLabel(formatMonthName(history.month, locale)),
    );
    final streakStat = _Stat(
      key: const Key('history-streak'),
      value: '$days',
      label: l10n.streakLabel(days),
    );
    // Stacked at large text: two columns of 120 px do not hold a Russian
    // label at x2.
    final compact = isCompactText(context);
    return compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              adherence,
              const Gap.v(PillPalSpacing.md),
              streakStat,
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: adherence),
              const Gap.h(PillPalSpacing.md),
              Expanded(child: streakStat),
            ],
          );
  }
}

/// A numeral over its caption, inside the calendar card.
class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, super.key});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: textTheme.numeral),
        Text(label, style: textTheme.bodySmall),
      ],
    );
  }
}
