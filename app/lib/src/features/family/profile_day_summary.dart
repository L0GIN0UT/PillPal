import '../common/local_time.dart';
import '../doses/dose_status.dart';
import '../doses/scheduled_doses.dart';

/// How a profile's day reads at a glance on the Family tab.
enum DaySummaryKind {
  /// Everything due today is marked taken (or deliberately skipped).
  allTaken,

  /// At least one dose is missed.
  missed,

  /// Nothing is missed, but some doses are still waiting.
  waiting,
}

/// Today's doses of one profile in numbers (R9, docs/redesign-plan.md).
///
/// A record, so equal summaries compare equal and a provider that rebuilds
/// to the same numbers does not repaint the row.
typedef ProfileDaySummary = ({
  int taken,
  int missed,
  int pending,
  int skipped,
  int total,
  DateTime? nextDue,
});

/// What a [ProfileDaySummary] says.
extension ProfileDaySummaryKind on ProfileDaySummary {
  /// The look of the day, or null when there is nothing to say: no doses, or
  /// only skipped ones (a deliberate choice is not news).
  DaySummaryKind? get kind {
    if (missed > 0) {
      return DaySummaryKind.missed;
    }
    if (pending > 0) {
      return DaySummaryKind.waiting;
    }
    return taken > 0 ? DaySummaryKind.allTaken : null;
  }
}

/// The numbers of the doses of [doses] that fall on the local day of [now]
/// in [zone] (the day view's window `[start, end)` of that zone, so the
/// day boundary and DST days agree with it).
///
/// [doses] are the profile's day-view doses with the statuses the dose-state
/// contract gave them at [now]; nothing is re-derived here. [nextDue] is the
/// earliest pending dose still ahead of [now].
ProfileDaySummary profileDaySummary(
  Iterable<ScheduledDose> doses,
  DateTime now,
  String zone,
) {
  final bounds = dayBounds(localDateOf(now, zone), zone);
  var taken = 0;
  var missed = 0;
  var pending = 0;
  var skipped = 0;
  DateTime? nextDue;
  for (final dose in doses) {
    final at = dose.dueAt;
    if (at.isBefore(bounds.start) || !at.isBefore(bounds.end)) {
      continue;
    }
    switch (dose.status) {
      case DoseStatus.taken:
        taken++;
      case DoseStatus.missed:
        missed++;
      case DoseStatus.skipped:
        skipped++;
      case DoseStatus.pending:
        pending++;
        if (at.isAfter(now) && (nextDue == null || at.isBefore(nextDue))) {
          nextDue = at;
        }
    }
  }
  return (
    taken: taken,
    missed: missed,
    pending: pending,
    skipped: skipped,
    total: taken + missed + pending + skipped,
    nextDue: nextDue,
  );
}

/// How long a profile's data may go without a sync before the Family tab
/// stops saying how the day is going and says how old the data is instead.
/// The owner's last sync is floored to the hour by the server (D5), so the
/// limit leaves room for that error.
const Duration staleDataAfter = Duration(hours: 6);

/// How old the data of a profile is, or null while it is fresh enough.
///
/// The data can only be as new as the oldest of the two syncs it passed
/// through: the owner's phone ([ownerLastSeenAt], other people's own
/// profiles only) and this device's ([lastSyncAt]). An unknown time says
/// nothing.
Duration? staleDataAge({
  required DateTime now,
  DateTime? ownerLastSeenAt,
  DateTime? lastSyncAt,
}) {
  final known = [
    if (ownerLastSeenAt != null) ownerLastSeenAt,
    if (lastSyncAt != null) lastSyncAt,
  ];
  if (known.isEmpty) {
    return null;
  }
  final oldest = known.reduce((a, b) => a.isBefore(b) ? a : b);
  final age = now.difference(oldest);
  return age >= staleDataAfter ? age : null;
}
