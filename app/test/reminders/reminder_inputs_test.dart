import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/reminders/reminder_inputs.dart';
import 'package:pillpal/src/reminders/reminder_payload.dart';
import 'package:pillpal/src/reminders/reminder_settings.dart';
import 'package:pillpal_core/pillpal_core.dart';

import 'reminder_test_env.dart';

DoseEventRow _event(
  String id,
  String type,
  int minute, {
  String key = 'k',
  String? target,
  int? snoozeUntilMinute,
}) {
  int at(int m) => DateTime.utc(2026, 10, 17, 4, m).microsecondsSinceEpoch;
  return DoseEventRow(
    id: id,
    profileId: 'p',
    medicationId: 'm',
    eventType: type,
    at: at(minute),
    occurrenceKey: key,
    targetEventId: target,
    snoozeUntil: snoozeUntilMinute == null ? null : at(snoozeUntilMinute),
  );
}

void main() {
  group('occurrenceStates', () {
    test('taken and skipped handle; undo reverts', () {
      final states = occurrenceStates([
        _event('a', 'taken', 1, key: 'k1'),
        _event('b', 'skipped', 2, key: 'k2'),
        _event('c', 'undo', 3, key: 'k2', target: 'b'),
      ]);
      expect(states.handled, {'k1'});
      expect(states.snoozedUntil, isEmpty);
    });

    test('the latest remaining snooze wins', () {
      final states = occurrenceStates([
        _event('s2', 'snoozed', 20, snoozeUntilMinute: 35),
        _event('s1', 'snoozed', 5, snoozeUntilMinute: 20),
        _event('s3', 'snoozed', 30, snoozeUntilMinute: 45),
        _event('u', 'undo', 31, target: 's3'),
      ]);
      expect(states.snoozedUntil, {'k': DateTime.utc(2026, 10, 17, 4, 35)});
    });
  });

  test('occurrence keys parse only in canonical form', () {
    const schedule = '0b000000-0000-4000-8000-00000000000b';
    final ref = occurrenceRefOf('$schedule/2026-10-17T08:00')!;
    expect(ref.scheduleId, schedule);
    expect(ref.localDate, LocalDate(2026, 10, 17));
    expect(ref.localTime, '08:00');
    for (final bad in [
      '$schedule/2026-10-17T8:00',
      '$schedule/2026-13-17T08:00',
      '$schedule/2026-10-17T24:00',
      '$schedule 2026-10-17T08:00',
      '/2026-10-17T08:00',
    ]) {
      expect(occurrenceRefOf(bad), isNull, reason: bad);
    }
  });

  test('loader: disabled medications and tombstones produce no target',
      () async {
    final env = await ReminderTestEnv.create();
    addTearDown(env.dispose);
    final ids = await env.seed();
    final loader = ReminderInputsLoader(env.data.db);

    var inputs = await loader.load(env.data.clock.now);
    expect(inputs.targets.keys, [ids.schedule]);
    expect(inputs.fallbackTimeZone, 'Europe/Samara');
    final fingerprint = inputs.targets[ids.schedule]!.scheduleFingerprint;

    await env.settings.setDefaults(ReminderSettings(enabled: false));
    inputs = await loader.load(env.data.clock.now);
    expect(inputs.targets, isEmpty);

    await env.settings.setOverride(
      ids.medication,
      ReminderSettings(level: ReminderLevel.alarm),
    );
    inputs = await loader.load(env.data.clock.now);
    final target = inputs.targets[ids.schedule]!;
    expect(target.source.level, ReminderLevel.alarm);
    expect(target.scheduleFingerprint, isNot(fingerprint));

    await env.data.schedules.delete(ids.schedule);
    inputs = await loader.load(env.data.clock.now);
    expect(inputs.targets, isEmpty);
  });
}
