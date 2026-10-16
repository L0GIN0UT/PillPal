import 'notification_request.dart';

/// The platform update that turns one plan into the next
/// (docs/spec/reminders.md §8).
class ReminderDiff {
  /// Creates a diff.
  const ReminderDiff({required this.cancelIds, required this.schedule});

  /// Ids to cancel, ascending.
  final List<int> cancelIds;

  /// Requests to schedule (new, or changed under the same id), in plan order.
  /// Scheduling an existing id replaces the pending notification.
  final List<NotificationRequest> schedule;

  /// Whether the platform is already up to date.
  bool get isEmpty => cancelIds.isEmpty && schedule.isEmpty;
}

/// The minimal update from the [previous] requests to the [next] ones.
ReminderDiff reconcile(
  Iterable<NotificationRequest> previous,
  Iterable<NotificationRequest> next,
) {
  final previousById = {for (final request in previous) request.id: request};
  final nextIds = {for (final request in next) request.id};
  final cancelIds = [
    for (final id in previousById.keys)
      if (!nextIds.contains(id)) id,
  ]..sort();
  final schedule = [
    for (final request in next)
      if (previousById[request.id] != request) request,
  ];
  return ReminderDiff(
    cancelIds: List<int>.unmodifiable(cancelIds),
    schedule: List<NotificationRequest>.unmodifiable(schedule),
  );
}
