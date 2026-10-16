import 'reminder_source.dart';

/// One local notification the device must have pending.
///
/// Holds only opaque ids, the occurrence key, the fire time and the level:
/// no medical text (`.claude/rules/privacy.md`). [toString] omits the key
/// because it encodes dose times.
class NotificationRequest {
  /// Creates a request; [fireAtUtc] is stored in UTC.
  NotificationRequest({
    required this.id,
    required this.occurrenceKey,
    required this.medicationId,
    required this.scheduleId,
    required DateTime fireAtUtc,
    required this.repeatIndex,
    required this.level,
    required this.isSnooze,
  }) : fireAtUtc = fireAtUtc.toUtc();

  /// Stable platform id in `1..2^31-1` (docs/spec/reminders.md §7).
  final int id;

  /// `{scheduleId}/{YYYY-MM-DD}T{HH:MM}` of the occurrence.
  final String occurrenceKey;

  /// Opaque medication id.
  final String medicationId;

  /// Opaque schedule id.
  final String scheduleId;

  /// When the notification fires (UTC).
  final DateTime fireAtUtc;

  /// 0 for the first notification of a series, k for the k-th repeat.
  final int repeatIndex;

  /// Reminder level, selects the platform channel / interruption level.
  final ReminderLevel level;

  /// Whether this request belongs to a snooze series.
  final bool isSnooze;

  @override
  bool operator ==(Object other) =>
      other is NotificationRequest &&
      other.id == id &&
      other.occurrenceKey == occurrenceKey &&
      other.medicationId == medicationId &&
      other.scheduleId == scheduleId &&
      other.fireAtUtc == fireAtUtc &&
      other.repeatIndex == repeatIndex &&
      other.level == level &&
      other.isSnooze == isSnooze;

  @override
  int get hashCode => Object.hash(
        id,
        occurrenceKey,
        medicationId,
        scheduleId,
        fireAtUtc,
        repeatIndex,
        level,
        isSnooze,
      );

  @override
  String toString() => 'NotificationRequest(id: $id, at: $fireAtUtc, '
      'repeat: $repeatIndex, level: ${level.name}, snooze: $isSnooze)';
}

/// The result of `ReminderPlanner.plan` (docs/spec/reminders.md §6).
class ReminderPlan {
  /// Creates a plan.
  const ReminderPlan({
    required this.requests,
    required this.replanBefore,
    required this.droppedByBudget,
    required this.unplannableScheduleIds,
  });

  /// Notifications to keep pending, ordered by fire time (spec §5).
  final List<NotificationRequest> requests;

  /// The planner must run again before this instant (UTC).
  final DateTime replanBefore;

  /// Candidates left out because of the budget.
  final int droppedByBudget;

  /// Enabled sources whose effective zone is unknown, sorted.
  final List<String> unplannableScheduleIds;
}
