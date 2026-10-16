import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../data/clock.dart';
import '../data/db/database.dart';
import 'flutter_notification_scheduler.dart';
import 'notification_scheduler.dart';
import 'reminder_actions.dart';
import 'reminder_service.dart';

/// `IsolateNameServer` name of the main isolate's port that learns about
/// dose events recorded by a notification action.
const String reminderEventsPortName = 'pillpal.reminders.events';

/// Message sent on [reminderEventsPortName] after an action was recorded.
const String doseEventRecordedMessage = 'dose_event_recorded';

/// Notification budget of this platform (ADR 0001 §9): iOS keeps 64
/// pending notifications (4 left for the app), Android's AlarmManager
/// about 500 per app.
int platformNotificationBudget() => defaultTargetPlatform == TargetPlatform.iOS
    ? iosPendingNotificationLimit - 4
    : androidDefaultNotificationBudget;

/// The device's IANA zone via `flutter_timezone`; null when unavailable.
Future<String?> deviceTimeZone() async {
  try {
    return (await FlutterTimezone.getLocalTimezone()).identifier;
  } on Object {
    return null;
  }
}

/// Entry point for notification actions that do not open the app (ADR 0001
/// §7). Runs in a separate isolate/engine, also when the app is terminated.
@pragma('vm:entry-point')
void onBackgroundNotificationResponse(NotificationResponse response) {
  unawaited(handleBackgroundResponse(response));
}

/// Records the action and re-plans; never throws and logs nothing (errors
/// may carry medical data). If anything fails, the next app start re-plans
/// and the dose stays unmarked on the Today screen.
Future<void> handleBackgroundResponse(NotificationResponse response) async {
  final action = ReminderAction.fromResponse(
    actionId: response.actionId,
    payload: response.payload,
  );
  if (action == null) {
    return;
  }
  AppDatabase? db;
  try {
    db = AppDatabase.open();
    final outcome = await runReminderAction(
      db: db,
      action: action,
      scheduler: FlutterNotificationScheduler(),
      clock: systemClock,
      newId: newUuid,
      deviceTimeZone: deviceTimeZone,
      locale: () => PlatformDispatcher.instance.locale,
      budget: platformNotificationBudget(),
    );
    if (outcome == ReminderActionOutcome.recorded) {
      IsolateNameServer.lookupPortByName(reminderEventsPortName)
          ?.send(doseEventRecordedMessage);
    }
  } on Object {
    // Intentionally silent, see above.
  } finally {
    await db?.close();
  }
}

/// Records [action] in [db] and re-plans the reminders: the occurrence's
/// notifications are settled (cancelled, tray included) and a snooze series
/// is scheduled. Only local writes: refresh tokens and the network are
/// never used here; the outbox is pushed by the main isolate.
Future<ReminderActionOutcome> runReminderAction({
  required AppDatabase db,
  required ReminderAction action,
  required NotificationScheduler scheduler,
  required Clock clock,
  required IdGenerator newId,
  required TimeZoneSource deviceTimeZone,
  required LocaleSource locale,
  required int budget,
}) async {
  final outcome = await ReminderActionHandler(
    db: db,
    clock: clock,
    newId: newId,
  ).handle(action);
  final service = ReminderService(
    db: db,
    scheduler: scheduler,
    clock: clock,
    deviceTimeZone: deviceTimeZone,
    locale: locale,
    budget: budget,
  );
  try {
    await service.replan();
  } finally {
    await service.dispose();
  }
  return outcome;
}
