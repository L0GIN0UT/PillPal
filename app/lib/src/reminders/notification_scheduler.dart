import 'package:flutter/foundation.dart';
import 'package:pillpal_core/pillpal_core.dart';

/// Identifiers of the notification actions (TZ §2.3).
abstract final class ReminderActionIds {
  /// "Taken".
  static const String taken = 'taken';

  /// "Snooze 15 min".
  static const String snooze = 'snooze';

  /// "Skip".
  static const String skip = 'skip';
}

/// Localized titles of the notification actions.
@immutable
class ReminderActionTitles {
  /// Creates titles.
  const ReminderActionTitles({
    required this.taken,
    required this.snooze,
    required this.skip,
  });

  /// "Taken".
  final String taken;

  /// "Snooze 15 min".
  final String snooze;

  /// "Skip".
  final String skip;
}

/// One notification to hand to the platform.
@immutable
class ScheduledReminder {
  /// Creates a reminder.
  const ScheduledReminder({
    required this.id,
    required this.fireAtUtc,
    required this.level,
    required this.exact,
    required this.title,
    required this.body,
    required this.payload,
    required this.threadId,
    required this.actions,
  });

  /// Platform id.
  final int id;

  /// Fire time (UTC); the platform receives it as a UTC instant.
  final DateTime fireAtUtc;

  /// Selects the channel / interruption level.
  final ReminderLevel level;

  /// Exact alarm (true) or inexact delivery (false), Android only.
  final bool exact;

  /// Visible title (already follows the medication's privacy).
  final String title;

  /// Visible body.
  final String body;

  /// Opaque payload: occurrence key and medication id, never medical text.
  final String payload;

  /// Opaque id shared by all notifications of one occurrence (iOS thread).
  final String threadId;

  /// Action titles.
  final ReminderActionTitles actions;
}

/// What the user allowed (checked on every re-plan).
@immutable
class ReminderPermissions {
  /// Creates permissions.
  const ReminderPermissions({
    required this.notificationsEnabled,
    required this.exactAlarmsAllowed,
    this.timeSensitiveAllowed = true,
  });

  /// Permissions before anything is known.
  static const ReminderPermissions unknown = ReminderPermissions(
    notificationsEnabled: true,
    exactAlarmsAllowed: true,
  );

  /// Whether the app may post notifications (Android 13+ runtime
  /// permission, iOS authorization).
  final bool notificationsEnabled;

  /// Whether exact alarms may be scheduled (Android 12+; always true on
  /// iOS).
  final bool exactAlarmsAllowed;

  /// iOS: whether Time Sensitive notifications are allowed (needs the
  /// entitlement and the user's setting). Off, persistent and alarm
  /// reminders arrive as ordinary ones and do not break through a Focus.
  /// True where it does not apply or is unknown.
  final bool timeSensitiveAllowed;

  @override
  bool operator ==(Object other) =>
      other is ReminderPermissions &&
      other.notificationsEnabled == notificationsEnabled &&
      other.exactAlarmsAllowed == exactAlarmsAllowed &&
      other.timeSensitiveAllowed == timeSensitiveAllowed;

  @override
  int get hashCode => Object.hash(
        notificationsEnabled,
        exactAlarmsAllowed,
        timeSensitiveAllowed,
      );
}

/// The platform refused an exact alarm (permission revoked meanwhile).
class ExactAlarmsNotPermitted implements Exception {
  /// Creates the exception.
  const ExactAlarmsNotPermitted();

  @override
  String toString() => 'ExactAlarmsNotPermitted';
}

/// The local-notification platform as the reminder service needs it.
///
/// The app uses `FlutterNotificationScheduler`; tests use a fake that
/// records calls.
abstract interface class NotificationScheduler {
  /// Current permissions.
  Future<ReminderPermissions> permissions();

  /// Ids of notifications that are scheduled and not yet delivered.
  Future<Set<int>> pendingIds();

  /// Schedules [reminder], replacing a pending one with the same id. Throws
  /// [ExactAlarmsNotPermitted] when an exact alarm is refused and
  /// [ArgumentError] when the fire time has already passed.
  Future<void> schedule(ScheduledReminder reminder);

  /// Cancels notification [id]: pending, and removes it from the tray.
  Future<void> cancel(int id);

  /// Cancels every notification of the app: pending ones and the tray.
  Future<void> cancelAll();
}
