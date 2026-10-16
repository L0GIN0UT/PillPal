import 'reconcile.dart';

/// Ids of retained notifications to cancel now, whatever their fire time
/// (docs/spec/reminders.md §8.1), ascending.
///
/// [retained] are all notifications applied to the platform and not yet
/// settled — pending, delayed (inexact alarms, Doze) or delivered. One is
/// settled when its occurrence is in [handledKeys]; when it belongs to a
/// regular series whose occurrence is in [snoozedKeys] (the snooze series
/// replaces it); or when [liveSchedules] (schedule id → current schedule
/// fingerprint of every enabled source) no longer lists its schedule or
/// lists a different fingerprint. Cancelling also removes the notification
/// from the tray.
List<int> settleIds({
  required Iterable<AppliedNotification> retained,
  required Set<String> handledKeys,
  required Set<String> snoozedKeys,
  required Map<String, String> liveSchedules,
}) {
  final ids = <int>{};
  for (final applied in retained) {
    final request = applied.request;
    final key = request.occurrenceKey;
    final live = liveSchedules[request.scheduleId];
    final replacedBySnooze = !request.isSnooze && snoozedKeys.contains(key);
    if (handledKeys.contains(key) ||
        replacedBySnooze ||
        live != applied.scheduleFingerprint) {
      ids.add(request.id);
    }
  }
  return List<int>.unmodifiable(ids.toList()..sort());
}
