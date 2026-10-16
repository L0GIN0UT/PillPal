import 'dart:ui';

import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/reminders/notification_scheduler.dart';
import 'package:pillpal/src/reminders/reminder_payload.dart';
import 'package:pillpal/src/reminders/reminder_service.dart';
import 'package:pillpal/src/reminders/reminder_settings_repository.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../data/test_env.dart';

/// Records what the reminder service asks of the platform and behaves like
/// it: delivered notifications move from the pending list to the [tray],
/// scheduling an existing id replaces it, past fire times are refused,
/// cancelling removes a notification from both.
class FakeNotificationScheduler implements NotificationScheduler {
  FakeNotificationScheduler(this.clock);

  final DateTime Function() clock;

  ReminderPermissions grants = const ReminderPermissions(
    notificationsEnabled: true,
    exactAlarmsAllowed: true,
  );

  /// Refuse exact alarms even though [grants] allows them (revoked later).
  bool refuseExact = false;

  /// The next this many [schedule] calls fail like a broken platform call.
  int failNextSchedules = 0;

  /// Ids whose alarm the OS dropped (force stop, OEM kill) while the
  /// plugin's cache - what [pendingIds] reads on Android - still lists them.
  final Set<int> lostAlarms = {};

  /// Drops every alarm but keeps the cache, like a force stop on Android.
  void forceStop() => lostAlarms.addAll(pending.keys);

  final Map<int, ScheduledReminder> pending = {};

  /// Delivered notifications still shown (moved here when their fire time
  /// has passed and the service looks at the pending list).
  final Map<int, ScheduledReminder> tray = {};
  final List<ScheduledReminder> scheduled = [];
  final List<int> cancelled = [];
  final List<String> calls = [];

  void clearLog() {
    scheduled.clear();
    cancelled.clear();
    calls.clear();
  }

  @override
  Future<ReminderPermissions> permissions() async => grants;

  @override
  Future<Set<int>> pendingIds() async {
    deliver();
    return pending.keys.toSet();
  }

  /// Moves every notification whose fire time has passed to the [tray].
  void deliver() {
    final now = clock();
    for (final entry in pending.entries.toList()) {
      if (!entry.value.fireAtUtc.isAfter(now)) {
        tray[entry.key] = entry.value;
        pending.remove(entry.key);
      }
    }
  }

  @override
  Future<void> schedule(ScheduledReminder reminder) async {
    if (refuseExact && reminder.exact) {
      throw const ExactAlarmsNotPermitted();
    }
    if (failNextSchedules > 0) {
      failNextSchedules--;
      calls.add('failed ${reminder.id}');
      throw StateError('platform call failed');
    }
    if (!reminder.fireAtUtc.isAfter(clock())) {
      throw ArgumentError.value(reminder.fireAtUtc, 'scheduledDate');
    }
    pending[reminder.id] = reminder;
    lostAlarms.remove(reminder.id);
    scheduled.add(reminder);
    calls.add('schedule ${reminder.id}');
  }

  @override
  Future<void> cancel(int id) async {
    pending.remove(id);
    tray.remove(id);
    cancelled.add(id);
    calls.add('cancel $id');
  }

  @override
  Future<void> cancelAll() async {
    pending.clear();
    tray.clear();
    calls.add('cancelAll');
  }

  /// Pending reminders ordered by fire time.
  List<ScheduledReminder> get byTime => pending.values.toList()
    ..sort((a, b) => a.fireAtUtc.compareTo(b.fireAtUtc));
}

/// A [TestEnv] (in-memory drift, fixed clock 2026-10-16T09:00Z = 13:00 in
/// Europe/Samara) with a reminder service over a fake scheduler.
class ReminderTestEnv {
  ReminderTestEnv._(this.data, {int budget = 400}) : _budget = budget {
    scheduler = FakeNotificationScheduler(data.clock.call);
    service = newService();
  }

  final int _budget;

  /// Another service over the same database and platform, like the one of
  /// a new process; the caller disposes it.
  ReminderService newService({bool rearmOnFirstReplan = false}) =>
      ReminderService(
        db: data.db,
        scheduler: scheduler,
        clock: data.clock.call,
        deviceTimeZone: () async => deviceTz,
        locale: () => locale,
        budget: _budget,
        rearmOnFirstReplan: rearmOnFirstReplan,
      );

  static Future<ReminderTestEnv> create({int budget = 400}) async =>
      ReminderTestEnv._(await TestEnv.create(signedIn: false), budget: budget);

  final TestEnv data;
  late final FakeNotificationScheduler scheduler;
  late final ReminderService service;
  String? deviceTz = 'Europe/Samara';
  Locale locale = const Locale('en');

  ReminderSettingsRepository get settings =>
      ReminderSettingsRepository(data.db);

  /// Profile, medication "Med A" (shared) and a daily 08:00 schedule.
  Future<({String profile, String medication, String schedule})> seed() =>
      data.seedLocal();

  /// The occurrence of [scheduleId] on 2026-10-[day] at [time].
  OccurrenceRef occurrence(String scheduleId, int day,
          [String time = '08:00']) =>
      OccurrenceRef(
        scheduleId: scheduleId,
        localDate: LocalDate(2026, 10, day),
        localTime: time,
      );

  /// The occurrence key of a pending reminder.
  static String keyOf(ScheduledReminder reminder) =>
      ReminderPayload.tryDecode(reminder.payload)!.occurrenceKey;

  Future<void> dispose() async {
    await service.dispose();
    await data.dispose();
  }
}
