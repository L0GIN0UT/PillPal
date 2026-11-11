import 'dart:ui' show Color;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/reminders/flutter_notification_scheduler.dart';
import 'package:pillpal/src/reminders/notification_scheduler.dart';
import 'package:pillpal/src/theme/palette.dart';
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

  test('Android notifications carry the light palette accent', () {
    for (final level in ReminderLevel.values) {
      final android = reminderNotificationDetails(_reminder(level)).android!;
      expect(android.color, PillPalPalette.light.action);
      expect(android.color, const Color(0xFF0C6B5D));
    }
  });

  test('the accent leaves payload, text, channel and actions as they were',
      () {
    final reminder = _reminder(ReminderLevel.normal);
    final android = reminderNotificationDetails(reminder).android!;
    expect(android.channelId, reminderChannelId(ReminderLevel.normal));
    expect(
      android.actions!.map((a) => (a.id, a.title)).toList(),
      [
        (ReminderActionIds.taken, 'Taken'),
        (ReminderActionIds.snooze, 'Snooze 15 min'),
        (ReminderActionIds.skip, 'Skip'),
      ],
    );
    expect(android.visibility, NotificationVisibility.private);
    expect(android.importance, Importance.high);
    expect(reminder.payload, '{"k":"s/2026-10-17T08:00","m":"m"}');
    expect(reminder.title, 'Time for your medication');
    expect(reminder.body, 'Open PillPal to mark the dose');
  });
}
