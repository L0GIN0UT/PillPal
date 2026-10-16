import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/reminders/notification_scheduler.dart';
import 'package:pillpal/src/reminders/reminder_settings.dart';
import 'package:pillpal_core/pillpal_core.dart';

import 'reminder_test_env.dart';

// now = 2026-10-16T09:00Z (13:00 in Europe/Samara, UTC+4); the seeded
// shared medication "Med A" reminds daily at 08:00 local = 04:00Z.

void main() {
  late ReminderTestEnv env;

  setUp(() async => env = await ReminderTestEnv.create());
  tearDown(() => env.dispose());

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
}
