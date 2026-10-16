import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/data/repositories/local_writer.dart';
import 'package:pillpal_core/pillpal_core.dart';

import 'test_env.dart';

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  OccurrenceRef occurrence(String scheduleId) => OccurrenceRef(
        scheduleId: scheduleId,
        localDate: LocalDate(2026, 10, 16),
        localTime: '08:00',
      );

  test('snooze stores snooze_until and pushes it', () async {
    final ids = await env.seedLocal();
    final at = env.clock.now;
    final until = at.add(const Duration(minutes: 15));

    final id = await env.doseEvents.snooze(
      medicationId: ids.medication,
      occurrence: occurrence(ids.schedule),
      at: at,
      until: until,
    );
    // Same id and payload again: idempotent.
    expect(
      await env.doseEvents.snooze(
        id: id,
        medicationId: ids.medication,
        occurrence: occurrence(ids.schedule),
        at: at,
        until: until,
      ),
      id,
    );

    final row = (await env.doseEvents.find(id))!;
    expect(row.eventType, 'snoozed');
    expect(row.snoozeUntil, until.microsecondsSinceEpoch);
    final entry = (await env.outbox()).lastWhere(
      (e) => e.entityKind == 'dose_event',
    );
    final payload = jsonDecode(entry.payload!) as Map<String, Object?>;
    expect(payload['snooze_until'], '2026-10-16T09:15:00.000Z');

    final report = await env.engine.sync();
    expect(report.ok, isTrue);
    expect(env.server.dataOf('dose_event', id)!['snooze_until'],
        '2026-10-16T09:15:00.000Z');
    // Pulled back: the row keeps its snooze instant.
    expect((await env.doseEvents.find(id))!.snoozeUntil,
        until.microsecondsSinceEpoch);
  });

  test('a different snooze_until under the same id conflicts', () async {
    final ids = await env.seedLocal();
    final at = env.clock.now;
    final id = await env.doseEvents.snooze(
      medicationId: ids.medication,
      occurrence: occurrence(ids.schedule),
      at: at,
      until: at.add(const Duration(minutes: 15)),
    );
    await expectLater(
      env.doseEvents.snooze(
        id: id,
        medicationId: ids.medication,
        occurrence: occurrence(ids.schedule),
        at: at,
        until: at.add(const Duration(minutes: 30)),
      ),
      throwsA(
        isA<DataException>()
            .having((e) => e.code, 'code', DataException.idempotencyConflict),
      ),
    );
  });

  test('snooze_until must be after at and within 24 hours', () async {
    final ids = await env.seedLocal();
    final at = env.clock.now;
    for (final until in [
      at,
      at.subtract(const Duration(minutes: 1)),
      at.add(const Duration(hours: 24, microseconds: 1)),
    ]) {
      await expectLater(
        env.doseEvents.snooze(
          medicationId: ids.medication,
          occurrence: occurrence(ids.schedule),
          at: at,
          until: until,
        ),
        throwsA(
          isA<DataException>().having((e) => e.field, 'field', 'snooze_until'),
        ),
      );
    }
    expect(
      await env.doseEvents.snooze(
        medicationId: ids.medication,
        occurrence: occurrence(ids.schedule),
        at: at,
        until: at.add(const Duration(hours: 24)),
      ),
      isNotEmpty,
    );
  });

  test('record() refuses snoozed (it needs snooze_until)', () async {
    final ids = await env.seedLocal();
    expect(
      () => env.doseEvents.record(
        medicationId: ids.medication,
        type: DoseEventType.snoozed,
        at: env.clock.now,
      ),
      throwsArgumentError,
    );
    // Other events do not send the field at all.
    await env.doseEvents.record(
      medicationId: ids.medication,
      type: DoseEventType.taken,
      at: env.clock.now,
    );
    final entry = (await env.outbox()).last;
    expect(jsonDecode(entry.payload!) as Map<String, Object?>,
        isNot(contains('snooze_until')));
  });

  test('pulled snoozes from another device keep snooze_until', () async {
    final ids = await env.seedLocal();
    await env.engine.sync();
    const id = '0e000000-0000-4000-8000-00000000000e';
    env.server.seed(
      'dose_event',
      id,
      data: {
        'profile_id': ids.profile,
        'medication_id': ids.medication,
        'type': 'snoozed',
        'at': '2026-10-16T08:00:00Z',
        'occurrence_key': occurrence(ids.schedule).key,
        'target_event_id': null,
        'note': null,
        'snooze_until': '2026-10-16T08:15:00Z',
        'recorded_at': '2026-10-16T08:00:01Z',
        'device_id': 'other-device',
      },
    );

    await env.engine.sync();

    final row = (await env.doseEvents.find(id))!;
    expect(
      row.snoozeUntil,
      DateTime.utc(2026, 10, 16, 8, 15).microsecondsSinceEpoch,
    );
  });
}
