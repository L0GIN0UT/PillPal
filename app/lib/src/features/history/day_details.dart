import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/spacing.dart';
import '../common/formatters.dart';
import '../common/gap.dart';
import '../common/local_time.dart';
import '../common/pillpal_card.dart';
import '../common/section_header.dart';
import '../common/status_kind.dart';
import '../common/status_pill.dart';
import '../doses/dose_status.dart';
import '../doses/scheduled_doses.dart';
import '../today/dose_tile.dart';
import 'history_model.dart';

/// Part of the day a dose is grouped under (B2-HistoryDay).
enum DayPart {
  /// Before noon.
  morning,

  /// From noon to 18:00.
  day,

  /// From 18:00 on.
  evening,
}

/// First hour of [DayPart.day] and [DayPart.evening] in a day's history.
const int _dayPartDayHour = 12;
const int _dayPartEveningHour = 18;

/// The part of the day of a wall-clock time `HH:MM`.
DayPart dayPartOf(String time) {
  final hour = int.parse(time.substring(0, 2));
  if (hour < _dayPartDayHour) {
    return DayPart.morning;
  }
  return hour < _dayPartEveningHour ? DayPart.day : DayPart.evening;
}

/// One line of a day's history: a scheduled dose or an as-needed intake.
class _Entry {
  const _Entry({
    required this.time,
    required this.title,
    required this.kind,
    this.detail = '',
    this.line = '',
  });

  final String time;
  final String title;
  final StatusKind kind;

  /// Dose and notes; empty for an anonymous medication.
  final String detail;

  /// "Taken at 08:04"; empty when the status word says it all.
  final String line;
}

/// The day behind a tapped calendar cell: a summary, then the entries grouped
/// by time of day, each with a status pill and, when marked, "Taken at ...".
class DayDetails extends StatelessWidget {
  /// Creates the details of [day] with times shown in [zone].
  const DayDetails({required this.day, required this.zone, super.key});

  /// The day.
  final DayHistory day;

  /// The zone the day's times are shown in.
  final String zone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final entries = _entries(context);
    return Column(
      key: const Key('history-day'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            formatLongDate(day.date, locale),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        if (entries.isEmpty) ...[
          const Gap.v(PillPalSpacing.sm),
          Text(
            l10n.dayNoEntries,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ] else ...[
          const Gap.v(PillPalSpacing.sm),
          _Summary(entries: entries),
          for (final part in DayPart.values)
            ..._group(l10n, part, [
              for (final entry in entries)
                if (dayPartOf(entry.time) == part) entry,
            ]),
        ],
      ],
    );
  }

  List<Widget> _group(AppLocalizations l10n, DayPart part, List<_Entry> rows) {
    if (rows.isEmpty) {
      return const [];
    }
    final title = switch (part) {
      DayPart.morning => l10n.dayPartMorning,
      DayPart.day => l10n.dayPartDay,
      DayPart.evening => l10n.dayPartEvening,
    };
    return [
      SectionHeader(title, titleKey: Key('day-part-${part.name}')),
      PillPalCard.rows(rows: [for (final row in rows) _EntryRow(row)]),
    ];
  }

  _Entry _doseEntry(BuildContext context, ScheduledDose dose) {
    final l10n = AppLocalizations.of(context);
    final markedAt = dose.mark?.at;
    return _Entry(
      time: doseTime(dose, zone),
      title: doseTitle(l10n, dose),
      detail: doseDetail(context, dose),
      kind: StatusKind.fromDose(dose.status),
      line: dose.status == DoseStatus.taken && markedAt != null
          ? l10n.takenAt(wallClockOf(markedAt, zone).hhmm)
          : '',
    );
  }

  /// Doses and intakes, in time order (stable for equal times).
  List<_Entry> _entries(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final entries = [
      for (final dose in day.doses) _doseEntry(context, dose),
      for (final intake in day.intakes)
        _Entry(
          time: wallClockOf(
            DateTime.fromMicrosecondsSinceEpoch(intake.at, isUtc: true),
            zone,
          ).hhmm,
          title: l10n.asNeededIntake,
          kind: StatusKind.taken,
        ),
    ];
    return entries..sort((a, b) => a.time.compareTo(b.time));
  }
}

/// "Taken 4" and "Missed 1" pills: the day in two words.
class _Summary extends StatelessWidget {
  const _Summary({required this.entries});

  final List<_Entry> entries;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final taken = entries.where((e) => e.kind == StatusKind.taken).length;
    final missed = entries.where((e) => e.kind == StatusKind.missed).length;
    return Wrap(
      spacing: PillPalSpacing.sm,
      runSpacing: PillPalSpacing.sm,
      children: [
        if (taken > 0)
          StatusPill(StatusKind.taken, label: l10n.daySummaryTaken(taken)),
        if (missed > 0)
          StatusPill(StatusKind.missed, label: l10n.daySummaryMissed(missed)),
      ],
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow(this.entry);

  final _Entry entry;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // At large text the time goes above the name instead of beside it
    // (docs/design.md, narrow screens).
    final compact = MediaQuery.textScalerOf(context).scale(1) >=
        PillPalSizes.compactRowScale;
    final time = Text(entry.time, style: textTheme.titleMedium);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(entry.title, style: textTheme.rowTitle),
        if (entry.detail.isNotEmpty)
          Text(entry.detail, style: textTheme.bodySmall),
        if (entry.line.isNotEmpty) Text(entry.line, style: textTheme.bodySmall),
        const Gap.v(PillPalSpacing.sm),
        StatusPill(entry.kind),
      ],
    );
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: PillPalSpacing.lg,
          vertical: PillPalSpacing.md,
        ),
        child: compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [time, const Gap.v(PillPalSpacing.xs), text],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: PillPalSizes.doseTimeWidth,
                    ),
                    child: time,
                  ),
                  const Gap.h(PillPalSpacing.md),
                  Expanded(child: text),
                ],
              ),
      ),
    );
  }
}
