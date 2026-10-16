import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/reminders/device_platform.dart';
import 'package:pillpal/src/reminders/notification_scheduler.dart';
import 'package:pillpal/src/reminders/reminder_payload.dart';
import 'package:pillpal/src/reminders/reminder_settings.dart';
import 'package:pillpal_core/pillpal_core.dart';

import 'reminder_test_env.dart';

// now = 2026-10-16T09:00Z (13:00 in Europe/Samara, UTC+4). The seeded
// schedule is daily at 08:00 local = 04:00Z, so the 48 h horizon holds the
// doses of Oct 17 and Oct 18.
final _oct17 = DateTime.utc(2026, 10, 17, 4);
final _oct18 = DateTime.utc(2026, 10, 18, 4);

void main() {
  late ReminderTestEnv env;

  setUp(() async => env = await ReminderTestEnv.create());
  tearDown(() => env.dispose());

  test('plans the next doses after a medication is created', () async {
    final ids = await env.seed();

    final status = await env.service.replan();

    final pending = env.scheduler.byTime;
    expect(pending.map((r) => r.fireAtUtc), [_oct17, _oct18]);
    expect(
      pending.map(ReminderTestEnv.keyOf),
      ['${ids.schedule}/2026-10-17T08:00', '${ids.schedule}/2026-10-18T08:00'],
    );
    final first = pending.first;
    expect(first.title, 'Time to take Med A');
    expect(first.body, 'Dose: 1 tab.');
    expect(first.level, ReminderLevel.normal);
    expect(first.exact, isTrue);
    expect(first.actions.snooze, 'Snooze 15 min');
    expect(
      ReminderPayload.tryDecode(first.payload)!.medicationId,
      ids.medication,
    );
    expect(first.payload, isNot(contains('Med A')));
    expect(first.threadId, occurrenceThreadId(ReminderTestEnv.keyOf(first)));
    expect(status.planned, 2);
    expect(status.droppedByBudget, 0);
    expect(status.timeZone, 'Europe/Samara');
    expect(status.failed, isFalse);
  });

  test('renders in the app language', () async {
    await env.seed();
    env.locale = const Locale('ru');

    await env.service.replan();

    expect(env.scheduler.byTime.first.title, 'Пора принять: Med A');
    expect(env.scheduler.byTime.first.body, 'Доза: 1 таб.');
    expect(env.scheduler.byTime.first.actions.taken, 'Принял');
  });

  test('re-planning without changes touches nothing', () async {
    await env.seed();
    await env.service.replan();
    env.scheduler.clearLog();

    await env.service.replan();

    expect(env.scheduler.calls, isEmpty);
  });

  test('a rewrite with the same content does not reschedule', () async {
    final ids = await env.seed();
    await env.service.replan();
    env.scheduler.clearLog();
    env.data.clock.advance(const Duration(minutes: 1));

    // New conflict key and outbox entry, identical content (as after a pull
    // that rewrote the row): the fingerprints ignore row versions.
    final row = (await env.data.medications.find(ids.medication))!;
    await env.data.medications
        .update(ids.medication, MedicationDraft.fromRow(row));
    await env.service.replan();

    expect(env.scheduler.calls, isEmpty);
  });

  test('taken cancels the occurrence, the others stay', () async {
    final ids = await env.seed();
    await env.service.replan();
    final oct17 = env.scheduler.byTime.first.id;
    env.scheduler.clearLog();

    await env.data.doseEvents.record(
      medicationId: ids.medication,
      type: DoseEventType.taken,
      at: env.data.clock.now,
      occurrence: env.occurrence(ids.schedule, 17),
    );
    await env.service.replan();

    expect(env.scheduler.cancelled, [oct17]);
    expect(env.scheduler.scheduled, isEmpty);
    expect(env.scheduler.byTime.map((r) => r.fireAtUtc), [_oct18]);
  });

  test('skip clears a delivered notification from the tray', () async {
    final ids = await env.seed();
    await env.service.replan();
    final oct17 = env.scheduler.byTime.first.id;
    // The 08:00 reminder fired and sits in the tray.
    env.data.clock.now = DateTime.utc(2026, 10, 17, 4, 10);
    await env.service.replan();
    expect(env.scheduler.pending.containsKey(oct17), isFalse);
    env.scheduler.clearLog();

    await env.data.doseEvents.record(
      medicationId: ids.medication,
      type: DoseEventType.skipped,
      at: env.data.clock.now,
      occurrence: env.occurrence(ids.schedule, 17),
    );
    await env.service.replan();

    expect(env.scheduler.cancelled, [oct17]);
  });

  test('snooze replaces the reminder and a second snooze reuses its id',
      () async {
    final ids = await env.seed();
    await env.service.replan();
    final regular = env.scheduler.byTime.first.id;
    env.data.clock.now = DateTime.utc(2026, 10, 17, 4, 5);
    final occurrence = env.occurrence(ids.schedule, 17);

    Future<ScheduledReminder> snooze() async {
      final now = env.data.clock.now;
      await env.data.doseEvents.snooze(
        medicationId: ids.medication,
        occurrence: occurrence,
        at: now,
        until: now.add(notificationSnooze),
      );
      env.scheduler.clearLog();
      await env.service.replan();
      // Later occurrences may enter the window too; pick this one's.
      return env.scheduler.scheduled
          .where((r) => ReminderTestEnv.keyOf(r) == occurrence.key)
          .single;
    }

    final first = await snooze();
    expect(env.scheduler.cancelled, [regular]);
    expect(first.fireAtUtc, DateTime.utc(2026, 10, 17, 4, 20));
    expect(first.body, 'Snoozed reminder. Dose: 1 tab.');
    expect(ReminderTestEnv.keyOf(first), occurrence.key);

    env.data.clock.now = DateTime.utc(2026, 10, 17, 4, 21);
    final second = await snooze();
    expect(second.id, first.id);
    expect(second.fireAtUtc, DateTime.utc(2026, 10, 17, 4, 36));
    expect(
      env.scheduler.pending.values.where((r) => r.payload == first.payload),
      hasLength(1),
    );
  });

  test('privacy change re-renders the text without the name', () async {
    final ids = await env.seed();
    await env.service.replan();
    final before = env.scheduler.pending.keys.toSet();
    env.scheduler.clearLog();

    final row = (await env.data.medications.find(ids.medication))!;
    final draft = MedicationDraft.fromRow(row);
    await env.data.medications.update(
      ids.medication,
      MedicationDraft(
        name: draft.name,
        tzMode: draft.tzMode,
        privacy: 'anonymous',
      ),
    );
    await env.service.replan();

    expect(env.scheduler.cancelled.toSet(), before);
    expect(env.scheduler.pending.keys.toSet(), before);
    for (final reminder in env.scheduler.pending.values) {
      expect(reminder.title, 'Time for your medication');
      expect(reminder.body, 'Open PillPal to mark the dose');
      expect('${reminder.title} ${reminder.body}', isNot(contains('Med A')));
    }
  });

  Future<void> setPrivacy(String medicationId, String privacy) async {
    final row = (await env.data.medications.find(medicationId))!;
    final draft = MedicationDraft.fromRow(row);
    await env.data.medications.update(
      medicationId,
      MedicationDraft(name: draft.name, tzMode: draft.tzMode, privacy: privacy),
    );
  }

  void expectGeneric(Iterable<ScheduledReminder> reminders) {
    expect(reminders, isNotEmpty);
    for (final reminder in reminders) {
      expect(reminder.title, 'Time for your medication');
      expect(reminder.body, 'Open PillPal to mark the dose');
    }
  }

  test('a hidden medication shows the generic text; payload is k and m only',
      () async {
    final ids = await env.seed();
    await setPrivacy(ids.medication, 'hidden');

    await env.service.replan();

    expectGeneric(env.scheduler.pending.values);
    for (final reminder in env.scheduler.pending.values) {
      final payload = jsonDecode(reminder.payload) as Map<String, Object?>;
      expect(payload.keys.toSet(), {'k', 'm'});
      expect(payload['m'], ids.medication);
      expect(reminder.payload, isNot(contains('Med A')));
      expect(reminder.payload, isNot(contains('tab')));
    }
  });

  test('shared -> hidden removes delivered notifications from the tray',
      () async {
    final ids = await env.seed();
    await env.service.replan();
    final oct17 = env.scheduler.byTime.first.id;
    // The Oct 17 reminder fired and shows the name in the tray.
    env.data.clock.now = DateTime.utc(2026, 10, 17, 4, 10);
    await env.service.replan();
    expect(env.scheduler.tray[oct17]!.title, 'Time to take Med A');

    await setPrivacy(ids.medication, 'hidden');
    await env.service.replan();

    expect(env.scheduler.tray, isEmpty);
    expectGeneric(env.scheduler.pending.values);
  });

  test('hiding medication names re-renders every reminder', () async {
    await env.seed();
    await env.service.replan();
    final before = env.scheduler.pending.keys.toSet();
    env.scheduler.clearLog();

    await env.settings.setHideMedicationNames(hide: true);
    await env.service.replan();

    expect(env.scheduler.cancelled.toSet(), before);
    expect(env.scheduler.pending.keys.toSet(), before);
    expectGeneric(env.scheduler.pending.values);
    env.scheduler.clearLog();

    await env.settings.setHideMedicationNames(hide: false);
    await env.service.replan();

    expect(env.scheduler.scheduled.map((r) => r.id).toSet(), before);
    for (final reminder in env.scheduler.pending.values) {
      expect(reminder.title, 'Time to take Med A');
    }
  });

  test('the name setting is a device setting: kept with the defaults',
      () async {
    final defaults = ReminderSettings(level: ReminderLevel.quiet);
    expect(await env.settings.hideMedicationNames(), isFalse);

    await env.settings.setHideMedicationNames(hide: true);
    expect(await env.settings.defaults(), ReminderSettings.builtIn);
    await env.settings.setDefaults(defaults);
    expect(await env.settings.hideMedicationNames(), isTrue);
    await env.data.db.wipeAccountData();

    expect(await env.settings.hideMedicationNames(), isTrue);
    expect(await env.settings.defaults(), defaults);
    expect(await env.settings.watchHideMedicationNames().first, isTrue);
  });

  test('persistent level repeats N/M and stops when taken', () async {
    final ids = await env.seed();
    await env.settings.setOverride(
      ids.medication,
      ReminderSettings(
        level: ReminderLevel.persistent,
        repeatEveryMinutes: 30,
        maxRepeats: 3,
      ),
    );

    await env.service.replan();
    final oct17 = env.scheduler.byTime.take(4).toList();
    expect(
      oct17.map((r) => r.fireAtUtc),
      [0, 30, 60, 90].map((m) => _oct17.add(Duration(minutes: m))),
    );
    expect(oct17[1].body, 'Not marked yet. Dose: 1 tab.');
    expect(env.scheduler.pending, hasLength(8));
    env.scheduler.clearLog();

    await env.data.doseEvents.record(
      medicationId: ids.medication,
      type: DoseEventType.taken,
      at: env.data.clock.now,
      occurrence: env.occurrence(ids.schedule, 17),
    );
    await env.service.replan();

    expect(env.scheduler.cancelled.toSet(), oct17.map((r) => r.id).toSet());
    expect(env.scheduler.pending, hasLength(4));
  });

  test('switching reminders off cancels them', () async {
    final ids = await env.seed();
    await env.service.replan();
    final before = env.scheduler.pending.keys.toSet();

    await env.settings.setOverride(
      ids.medication,
      ReminderSettings(enabled: false),
    );
    await env.service.replan();

    expect(env.scheduler.cancelled.toSet(), before);
    expect(env.scheduler.pending, isEmpty);
  });

  test('budget truncates the plan and reports replanBefore', () async {
    await env.dispose();
    env = await ReminderTestEnv.create(budget: 1);
    await env.seed();

    final status = await env.service.replan();

    expect(env.scheduler.byTime.map((r) => r.fireAtUtc), [_oct17]);
    expect(status.droppedByBudget, 1);
    expect(status.replanBefore, _oct18);
  });

  test('a device zone change moves local schedules, not fixed ones', () async {
    final ids = await env.seed();
    final fixed = await env.data.medications.create(
      profileId: ids.profile,
      draft: const MedicationDraft(
        name: 'Med B',
        tzMode: 'fixed',
        fixedTz: 'Europe/Samara',
      ),
    );
    await env.data.schedules.create(
      medicationId: fixed,
      rule: {
        'v': 1,
        'kind': 'daily',
        'start_date': '2026-10-01',
        'end_date': null,
        'times': [
          {
            'time': '20:00',
            'dose': {'amount': '1', 'unit': 'capsule'},
          },
        ],
      },
    );
    await env.service.replan();
    final before = {
      for (final r in env.scheduler.pending.values) r.id: r.fireAtUtc,
    };
    env.scheduler.clearLog();

    env.deviceTz = 'Europe/Moscow'; // UTC+3
    final status = await env.service.replan();

    expect(status.timeZone, 'Europe/Moscow');
    // Same ids, rescheduled in place; Med B (fixed zone) is untouched.
    expect(env.scheduler.cancelled, isEmpty);
    expect(env.scheduler.scheduled, hasLength(2));
    for (final reminder in env.scheduler.scheduled) {
      expect(reminder.title, 'Time to take Med A');
      expect(
        reminder.fireAtUtc,
        before[reminder.id]!.add(const Duration(hours: 1)),
      );
    }
    expect(env.scheduler.pending.keys.toSet(), before.keys.toSet());
  });

  test('an unknown device zone falls back to the profile zone', () async {
    await env.seed();
    env.deviceTz = 'Mars/Olympus';

    final status = await env.service.replan();

    expect(status.timeZone, 'Europe/Samara');
    expect(env.scheduler.byTime.first.fireAtUtc, _oct17);
  });

  test('exact alarms: inexact when denied, upgraded when granted', () async {
    await env.seed();
    env.scheduler.grants = const ReminderPermissions(
      notificationsEnabled: true,
      exactAlarmsAllowed: false,
    );
    final denied = await env.service.replan();
    expect(denied.exactAlarms, isFalse);
    expect(
        env.scheduler.pending.values.map((r) => r.exact), everyElement(false));
    final ids = env.scheduler.pending.keys.toSet();
    env.scheduler.clearLog();

    env.scheduler.grants = ReminderPermissions.unknown;
    await env.service.replan();

    expect(env.scheduler.cancelled.toSet(), ids);
    expect(env.scheduler.scheduled.map((r) => r.id).toSet(), ids);
    expect(
        env.scheduler.pending.values.map((r) => r.exact), everyElement(true));
  });

  test('Time Sensitive off degrades only plans with repeating levels',
      () async {
    final ids = await env.seed();
    env.scheduler.grants = const ReminderPermissions(
      notificationsEnabled: true,
      exactAlarmsAllowed: true,
      timeSensitiveAllowed: false,
    );
    expect((await env.service.replan()).timeSensitiveDegraded, isFalse);

    await env.settings.setOverride(
      ids.medication,
      ReminderSettings(level: ReminderLevel.persistent),
    );
    final status = await env.service.replan();

    expect(status.timeSensitiveDegraded, isTrue);
    expect(status.permissions.timeSensitiveAllowed, isFalse);
  });

  test('time sensitive setting names map to allowed / not / unknown', () {
    expect(timeSensitiveFromSetting('enabled'), isTrue);
    expect(timeSensitiveFromSetting('disabled'), isFalse);
    expect(timeSensitiveFromSetting('notSupported'), isNull);
    expect(timeSensitiveFromSetting(null), isNull);
  });

  test('a refused exact alarm re-applies the plan inexact', () async {
    await env.seed();
    env.scheduler.refuseExact = true;

    final status = await env.service.replan();

    expect(status.exactAlarms, isFalse);
    expect(env.scheduler.pending, hasLength(2));
    expect(
        env.scheduler.pending.values.map((r) => r.exact), everyElement(false));
  });

  test('pending list check: lost reminders return, strays are cancelled',
      () async {
    await env.seed();
    await env.service.replan();
    final lost = env.scheduler.byTime.first;
    env.scheduler.pending.remove(lost.id); // e.g. dropped on boot
    const stray = 12345;
    env.scheduler.pending[stray] = lost;
    env.scheduler.pending[firstAppNotificationId] = lost; // not ours
    env.scheduler.clearLog();

    await env.service.replan();

    expect(env.scheduler.cancelled, [stray]);
    expect(env.scheduler.scheduled.map((r) => r.id), [lost.id]);
    expect(env.scheduler.pending.containsKey(firstAppNotificationId), isTrue);
  });

  test('Android: a new process re-arms every future reminder once', () async {
    await env.seed();
    await env.service.replan();
    final armed = env.scheduler.pending.keys.toSet();
    env.scheduler.forceStop();
    env.scheduler.clearLog();

    // Same process: the cache says pending, nothing is noticed.
    await env.service.replan();
    expect(env.scheduler.calls, isEmpty);

    final restarted = env.newService(rearmOnFirstReplan: true);
    addTearDown(restarted.dispose);
    await restarted.replan();

    expect(env.scheduler.scheduled.map((r) => r.id).toSet(), armed);
    expect(env.scheduler.cancelled, isEmpty);
    expect(env.scheduler.lostAlarms, isEmpty);
    env.scheduler.clearLog();

    await restarted.replan();
    expect(env.scheduler.calls, isEmpty);
  });

  test('iOS: a new process trusts the pending list', () async {
    await env.seed();
    await env.service.replan();
    env.scheduler.clearLog();

    final restarted = env.newService();
    addTearDown(restarted.dispose);
    await restarted.replan();

    expect(env.scheduler.calls, isEmpty);
  });

  test('one refused notification does not stop the others', () async {
    await env.seed();
    env.scheduler.failNextSchedules = 1;

    final failed = await env.service.replan();

    expect(failed.failed, isTrue);
    expect(env.scheduler.byTime.map((r) => r.fireAtUtc), [_oct18]);
    final db = env.data.db;
    expect(await db.select(db.appliedNotifications).get(), hasLength(1));

    final retried = await env.service.replan();

    expect(retried.failed, isFalse);
    expect(env.scheduler.byTime.map((r) => r.fireAtUtc), [_oct17, _oct18]);
    expect(await db.select(db.appliedNotifications).get(), hasLength(2));
  });

  test('a deleted medication settles its notifications', () async {
    final ids = await env.seed();
    await env.service.replan();
    final before = env.scheduler.pending.keys.toSet();

    await env.data.medications.delete(ids.medication);
    await env.service.replan();

    expect(env.scheduler.cancelled.toSet(), before);
    expect(env.scheduler.pending, isEmpty);
  });

  test('concurrent calls are serialized and coalesced', () async {
    await env.seed();

    final results = await Future.wait([
      env.service.replan(),
      env.service.replan(),
      env.service.replan(),
    ]);

    expect(results.map((s) => s.planned), everyElement(2));
    expect(env.scheduler.scheduled, hasLength(2));
  });
}
