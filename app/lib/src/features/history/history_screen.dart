import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/palette.dart';
import '../common/formatters.dart';
import '../common/local_time.dart';
import '../doses/dose_status.dart';
import '../family/archived_profile_banner.dart';
import '../family/profile_context.dart';
import '../family/profile_note.dart';
import '../family/profile_switcher.dart';
import '../report/report_sheet.dart';
import '../today/dose_tile.dart';
import 'history_model.dart';
import 'history_providers.dart';
import 'month_calendar.dart';

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
        title: Text(
          other == null
              ? l10n.historyTitle
              : l10n.historyOf(other.profile.displayName),
        ),
      ),
      body: history.when(
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(child: Text(l10n.errorGeneric)),
        data: (data) {
          final day = selected == null ? null : data.day(selected);
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              if (profileId == null) const ProfileSwitcher(),
              if (access != null && access.archived)
                ArchivedProfileBanner(access: access),
              if (other != null) ProfileNote(access: other),
              _StatsRow(history: data, streak: streak),
              const SizedBox(height: 12),
              MonthCalendar(
                history: data,
                selected: selected,
                onSelect: (date) => ref
                    .read(historySelectedDayProvider.notifier)
                    .select(date == selected ? null : date),
                onPrevious: () => month.show(previousMonthStart(data.month)),
                onNext: () => month.show(nextMonthStart(data.month)),
              ),
              if (day != null) ...[
                const SizedBox(height: 12),
                _DayDetails(day: day, zone: zone),
              ],
              const SizedBox(height: 16),
              OutlinedButton.icon(
                key: const Key('history-pdf'),
                onPressed: () => showReportSheet(context, profileId: shown),
                icon: const Icon(Icons.description_outlined),
                label: Text(l10n.pdfReport),
              ),
            ],
          );
        },
      ),
    );
  }
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _StatCard(
            key: const Key('history-percent'),
            value: percent == null ? '—' : '$percent%',
            label: l10n.adherenceLabel(formatMonthName(history.month, locale)),
            color: context.palette.taken,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatCard(
            key: const Key('history-streak'),
            value: '$days',
            label: l10n.streakLabel(days),
          ),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.value,
    required this.label,
    this.color,
    super.key,
  });

  final String value;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: textTheme.headlineLarge?.copyWith(color: color),
            ),
            Text(label, style: textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _DayDetails extends StatelessWidget {
  const _DayDetails({required this.day, required this.zone});

  final DayHistory day;

  /// The zone the day's times are shown in.
  final String zone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final tz = zone;
    final hasEntries = day.doses.isNotEmpty || day.intakes.isNotEmpty;
    return Card(
      key: const Key('history-day'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(formatLongDate(day.date, locale),
                style: textTheme.titleMedium),
            const SizedBox(height: 8),
            if (!hasEntries)
              Text(l10n.dayNoEntries, style: textTheme.bodySmall),
            for (final dose in day.doses)
              _EntryRow(
                time: doseTime(dose, tz),
                title: doseTitle(l10n, dose),
                status: _statusText(l10n, dose.status, dose.mark?.at, tz),
              ),
            for (final intake in day.intakes)
              _EntryRow(
                time: wallClockOf(
                  DateTime.fromMicrosecondsSinceEpoch(intake.at, isUtc: true),
                  tz,
                ).hhmm,
                title: l10n.asNeededIntake,
                status: l10n.statusTaken,
              ),
          ],
        ),
      ),
    );
  }

  String _statusText(
    AppLocalizations l10n,
    DoseStatus status,
    DateTime? markedAt,
    String tz,
  ) {
    switch (status) {
      case DoseStatus.taken:
        return markedAt == null
            ? l10n.statusTaken
            : l10n.takenAt(wallClockOf(markedAt, tz).hhmm);
      case DoseStatus.skipped:
        return l10n.statusSkipped;
      case DoseStatus.missed:
        return l10n.statusMissed;
      case DoseStatus.pending:
        return l10n.statusPending;
    }
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.time,
    required this.title,
    required this.status,
  });

  final String time;
  final String title;
  final String status;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 56, child: Text(time, style: textTheme.titleSmall)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: textTheme.titleSmall),
                Text(status, style: textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
