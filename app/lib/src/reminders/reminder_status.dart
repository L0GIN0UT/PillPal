import 'package:flutter/foundation.dart';

import 'notification_scheduler.dart';

/// Outcome of the latest re-plan, for banners on the Today screen.
@immutable
class ReminderStatus {
  /// Creates a status.
  const ReminderStatus({
    this.plannedAt,
    this.planned = 0,
    this.droppedByBudget = 0,
    this.unplannableScheduleIds = const [],
    this.replanBefore,
    this.permissions = ReminderPermissions.unknown,
    this.exactAlarms = true,
    this.timeZone,
    this.failed = false,
    this.timeSensitiveDegraded = false,
  });

  /// When the latest successful re-plan ran; null before the first one.
  final DateTime? plannedAt;

  /// Notifications in the current plan.
  final int planned;

  /// Notifications left out by the budget (iOS 64 limit): later reminders
  /// exist only if the app runs again before [replanBefore].
  final int droppedByBudget;

  /// Schedules whose zone is unknown (not reminded).
  final List<String> unplannableScheduleIds;

  /// The plan must be refreshed before this instant.
  final DateTime? replanBefore;

  /// Permissions seen by the latest re-plan.
  final ReminderPermissions permissions;

  /// Whether exact alarms were used.
  final bool exactAlarms;

  /// The zone `local` schedules were planned in.
  final String? timeZone;

  /// Whether the latest re-plan failed (details are not kept: they may
  /// contain medical data).
  final bool failed;

  /// iOS: the plan has persistent or alarm reminders but Time Sensitive
  /// notifications are off, so they do not break through a Focus.
  final bool timeSensitiveDegraded;
}
