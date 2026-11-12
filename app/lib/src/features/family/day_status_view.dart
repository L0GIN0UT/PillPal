import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../common/local_time.dart';
import '../common/status_kind.dart';
import '../common/status_pill.dart';
import 'day_hint.dart';
import 'day_status_providers.dart';
import 'profile_day_summary.dart';

/// What a Family row says about the day of a profile: a status pill and a
/// quiet line under the name; either may be missing.
typedef DayStatusParts = ({Widget? pill, Widget? detail});

const DayStatusParts _nothing = (pill: null, detail: null);

/// The pill and the line of [status] for the row of [profileId] (R9).
///
/// Nothing for no [status] (not loaded, no access) and nothing for a day
/// without doses. With stale data the pill gives way to how old the data is:
/// a status that may be wrong is worse than none. A missed dose is the calm
/// iris pill, never red.
///
/// A dose that is pending but already due (inside its grace period) counts
/// as waiting and is not the "next" one: [ProfileDaySummary.nextDue] is the
/// first pending dose still ahead.
DayStatusParts dayStatusParts(
  AppLocalizations l10n,
  ProfileDayStatus? status,
  String profileId,
) {
  final summary = status?.summary;
  if (status == null || summary == null || summary.total == 0) {
    return _nothing;
  }
  final age = status.staleAge;
  if (age != null) {
    return (
      pill: null,
      detail: DayHint(
        key: Key('day-stale-$profileId'),
        icon: Icons.history,
        text: age.inHours >= Duration.hoursPerDay * 2
            ? l10n.familyUpdatedDaysAgo(age.inDays)
            : l10n.familyUpdatedHoursAgo(age.inHours),
      ),
    );
  }
  final next = summary.nextDue;
  return (
    pill: _pill(l10n, summary, profileId),
    detail: next == null
        ? null
        : DayHint(
            key: Key('day-next-$profileId'),
            icon: Icons.schedule,
            text: l10n.familyNextDose(wallClockOf(next, status.zone).hhmm),
          ),
  );
}

Widget? _pill(
  AppLocalizations l10n,
  ProfileDaySummary summary,
  String profileId,
) {
  final key = Key('day-status-$profileId');
  return switch (summary.kind) {
    DaySummaryKind.allTaken =>
      StatusPill(StatusKind.taken, key: key, label: l10n.familyDayAllTaken),
    DaySummaryKind.missed => StatusPill(
        StatusKind.missed,
        key: key,
        label: l10n.familyDayMissed(summary.missed),
      ),
    DaySummaryKind.waiting => StatusPill(
        StatusKind.pending,
        key: key,
        label: l10n.familyDayProgress(summary.taken, summary.total),
      ),
    null => null,
  };
}
