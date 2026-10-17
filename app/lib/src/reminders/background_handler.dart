import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../data/clock.dart';
import '../data/db/database.dart';
import '../data/db/sync_state_store.dart';
import '../data/repositories/local_writer.dart';
import '../data/repositories/profiles_repository.dart';
import '../features/common/local_time.dart' show isKnownTimeZone;
import '../home_widget/home_widget_channel.dart';
import '../home_widget/home_widget_updater.dart';
import 'flutter_notification_scheduler.dart';
import 'notification_scheduler.dart';
import 'reminder_actions.dart';
import 'reminder_service.dart';

/// `IsolateNameServer` name of the main isolate's port that learns about
/// dose events recorded by a notification action.
const String reminderEventsPortName = 'pillpal.reminders.events';

/// Message sent on [reminderEventsPortName] after an action was handled,
/// as `[doseEventRecordedMessage, SendPort reply]`.
const String doseEventRecordedMessage = 'dose_event_recorded';

/// How long the background isolate waits for the main isolate to confirm
/// that it takes over the re-plan.
const Duration mainIsolateAnswerTimeout = Duration(seconds: 2);

/// Tells the main isolate behind [port] (the `IsolateNameServer` lookup of
/// [reminderEventsPortName]) that a dose event was written; true if it
/// answered, i.e. it is alive and re-plans itself. False without a port or
/// without an answer within [timeout] (a registration left behind by a
/// detached engine): the background isolate then re-plans on its own.
Future<bool> handOverToMainIsolate(
  SendPort? port, {
  Duration timeout = mainIsolateAnswerTimeout,
}) async {
  if (port == null) {
    return false;
  }
  final answer = ReceivePort();
  try {
    port.send([doseEventRecordedMessage, answer.sendPort]);
    await answer.first.timeout(timeout);
    return true;
  } on TimeoutException {
    return false;
  } finally {
    answer.close();
  }
}

/// The main isolate's side of [handOverToMainIsolate]: answers a
/// background message at once and calls [onDoseEvent] (refresh streams,
/// re-plan, push). Other messages are ignored.
void answerBackgroundMessage(Object? message, void Function() onDoseEvent) {
  if (message is List<Object?> &&
      message.length == 2 &&
      message.first == doseEventRecordedMessage) {
    final reply = message.last;
    if (reply is SendPort) {
      reply.send(true);
    }
    onDoseEvent();
  }
}

Future<bool> _mainIsolateAbsent() async => false;

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
  // Plugins (drift's path provider, the notification plugin) must be
  // registered in this isolate before any channel call.
  DartPluginRegistrant.ensureInitialized();
  unawaited(handleBackgroundResponse(response));
}

/// Records the action and makes sure a re-plan follows; never throws and
/// logs nothing (errors may carry medical data). If anything fails, the
/// next app start re-plans and the dose stays unmarked on the Today screen.
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
    await runReminderAction(
      db: db,
      action: action,
      scheduler: FlutterNotificationScheduler(),
      clock: systemClock,
      newId: newUuid,
      deviceTimeZone: deviceTimeZone,
      locale: () => PlatformDispatcher.instance.locale,
      budget: platformNotificationBudget(),
      mainIsolateReplans: () => handOverToMainIsolate(
        IsolateNameServer.lookupPortByName(reminderEventsPortName),
      ),
    );
    // A mark from the tray updates the home-screen widget even when the app
    // is not running (the main isolate, if alive, refreshes it as well).
    await HomeWidgetUpdater(
      db: db,
      clock: systemClock,
      deviceTimeZone: deviceTimeZone,
      locale: () => PlatformDispatcher.instance.locale,
      channel: const PluginHomeWidgetChannel(),
    ).refresh();
  } on Object {
    // Intentionally silent, see above.
  } finally {
    await db?.close();
  }
}

/// Records [action] in [db], then re-plans: by the main isolate when
/// [mainIsolateReplans] says it is running (it owns the plan, two planners
/// would race), else here - the occurrence's notifications are settled
/// (cancelled, tray included) and a snooze series is scheduled. Only local
/// writes: refresh tokens and the network are never used here; the outbox
/// is pushed by the main isolate.
Future<ReminderActionOutcome> runReminderAction({
  required AppDatabase db,
  required ReminderAction action,
  required NotificationScheduler scheduler,
  required Clock clock,
  required IdGenerator newId,
  required TimeZoneSource deviceTimeZone,
  required LocaleSource locale,
  required int budget,
  Future<bool> Function() mainIsolateReplans = _mainIsolateAbsent,
}) async {
  final outcome = await ReminderActionHandler(
    db: db,
    clock: clock,
    newId: newId,
  ).handle(action);
  if (await mainIsolateReplans()) {
    return outcome;
  }
  await _followDeviceZone(db, clock, newId, deviceTimeZone);
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

/// The own `self` profile follows the phone's zone (D4): when the phone
/// moved while the app was not running, the re-plan of this isolate must
/// read the new zone, and the main isolate pushes the change at its next
/// start. Best effort and local only; the zone is not logged.
Future<void> _followDeviceZone(
  AppDatabase db,
  Clock clock,
  IdGenerator newId,
  TimeZoneSource deviceTimeZone,
) async {
  try {
    final zone = await deviceTimeZone();
    if (zone == null || !isKnownTimeZone(zone)) {
      return;
    }
    await ProfilesRepository(
      LocalWriter(
        db: db,
        syncState: SyncStateStore(db, newId),
        clock: clock,
        newId: newId,
      ),
    ).syncDeviceZone(zone);
  } on Object {
    // The re-plan then uses the zone the profile has.
  }
}
