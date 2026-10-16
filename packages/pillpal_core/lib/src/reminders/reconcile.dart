import 'notification_request.dart';

/// A request as applied to the platform, with the caller's fingerprints.
///
/// Both fingerprints are opaque strings computed by the app
/// (docs/spec/reminders.md §8): [displayFingerprint] covers everything that
/// changes how the notification looks or is delivered (channel, schedule
/// mode, privacy, locale, text); [scheduleFingerprint] identifies the
/// schedule and medication state it was planned from.
class AppliedNotification {
  /// Creates an applied notification.
  const AppliedNotification(
    this.request, {
    required this.displayFingerprint,
    required this.scheduleFingerprint,
  });

  /// The planned request.
  final NotificationRequest request;

  /// Opaque fingerprint of the presentation.
  final String displayFingerprint;

  /// Opaque fingerprint of the schedule it was planned from.
  final String scheduleFingerprint;

  /// The platform id.
  int get id => request.id;

  @override
  bool operator ==(Object other) =>
      other is AppliedNotification &&
      other.request == request &&
      other.displayFingerprint == displayFingerprint &&
      other.scheduleFingerprint == scheduleFingerprint;

  @override
  int get hashCode =>
      Object.hash(request, displayFingerprint, scheduleFingerprint);
}

/// The platform update that turns one plan into the next
/// (docs/spec/reminders.md §8).
class ReminderDiff {
  /// Creates a diff.
  const ReminderDiff({required this.cancelIds, required this.schedule});

  /// Ids to cancel, ascending. Cancel them before scheduling.
  final List<int> cancelIds;

  /// Notifications to schedule, in plan order. Scheduling an existing id
  /// replaces the pending notification.
  final List<AppliedNotification> schedule;

  /// Whether the platform is already up to date.
  bool get isEmpty => cancelIds.isEmpty && schedule.isEmpty;
}

/// The minimal update from the [previous] notifications to the [next] ones.
///
/// Previous notifications firing at or before [now] are left to
/// `settleIds`: they may already be in the tray. A future one is cancelled
/// when its id leaves the plan or its display fingerprint changed (it is
/// then rescheduled under the same id); a changed request is rescheduled.
ReminderDiff reconcile(
  Iterable<AppliedNotification> previous,
  Iterable<AppliedNotification> next, {
  required DateTime now,
}) {
  final previousById = {
    for (final applied in previous)
      if (applied.request.fireAtUtc.isAfter(now)) applied.id: applied,
  };
  final nextById = {for (final applied in next) applied.id: applied};
  final cancelIds = <int>[];
  for (final MapEntry(key: id, value: old) in previousById.entries) {
    final replacement = nextById[id];
    if (replacement == null ||
        replacement.displayFingerprint != old.displayFingerprint) {
      cancelIds.add(id);
    }
  }
  cancelIds.sort();
  final schedule = [
    for (final applied in next)
      if (previousById[applied.id] != applied) applied,
  ];
  return ReminderDiff(
    cancelIds: List<int>.unmodifiable(cancelIds),
    schedule: List<AppliedNotification>.unmodifiable(schedule),
  );
}
