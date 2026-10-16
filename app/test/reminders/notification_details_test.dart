import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/reminders/flutter_notification_scheduler.dart';
import 'package:pillpal/src/reminders/notification_scheduler.dart';
import 'package:pillpal_core/pillpal_core.dart';

ScheduledReminder _reminder(ReminderLevel level) => ScheduledReminder(
      id: 1,
      fireAtUtc: DateTime.utc(2026, 10, 17, 4),
      level: level,
      exact: true,
      title: 'Time for your medication',
      body: 'Open PillPal to mark the dose',
      payload: '{"k":"s/2026-10-17T08:00","m":"m"}',
      threadId: '0000abcd',
      actions: const ReminderActionTitles(
        taken: 'Taken',
        snooze: 'Snooze 15 min',
        skip: 'Skip',
      ),
    );

void main() {
  test('Android reminders are private on a secure lock screen', () {
    for (final level in ReminderLevel.values) {
      final details = reminderNotificationDetails(_reminder(level));
      expect(details.android!.visibility, NotificationVisibility.private);
      expect(details.android!.channelId, reminderChannelId(level));
      expect(details.iOS!.threadIdentifier, '0000abcd');
      expect(
        details.iOS!.interruptionLevel,
        reminderInterruptionLevel(level),
      );
    }
  });
}
