import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/data/repositories/local_writer.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/data/repositories/schedules_repository.dart';
import 'package:pillpal/src/features/doses/dose_status.dart';
import 'package:pillpal_core/pillpal_core.dart';

import 'test_env.dart';

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  group('nextConflictKey', () {
    test('follows the clock while it moves forward', () {
      final now = DateTime.utc(2026, 10, 16, 9);
      expect(nextConflictKey(now, null), now.microsecondsSinceEpoch);
      expect(
        nextConflictKey(now, now.microsecondsSinceEpoch - 5),
        now.microsecondsSinceEpoch,
      );
    });

    test('is previous + 1us when the clock is behind or equal', () {
      final now = DateTime.utc(2026, 10, 16, 9);
      final previous = now.microsecondsSinceEpoch + 1000;
      expect(nextConflictKey(now, previous), previous + 1);
      expect(
        nextConflictKey(now, now.microsecondsSinceEpoch),
        now.microsecondsSinceEpoch + 1,
      );
    });
  });

  test('every write stores the row and its outbox entry, in order', () async {
    final ids = await env.seedLocal();
    await env.medications.update(
      ids.medication,
      const MedicationDraft(name: 'Med B', notes: 'after meals'),
    );
    await env.schedules.delete(ids.schedule);

    final outbox = await env.outbox();
    expect(
      [for (final e in outbox) '${e.entityKind}:${e.op}:${e.entityId}'],
      [
        'profile:upsert:${ids.profile}',
        'medication:upsert:${ids.medication}',
        'schedule:upsert:${ids.schedule}',
        'medication:upsert:${ids.medication}',
        'schedule:delete:${ids.schedule}',
      ],
    );
    expect(outbox.map((e) => e.seq).toList(), orderedEquals([1, 2, 3, 4, 5]));
    expect(outbox.last.payload, isNull);
    final medication = jsonDecode(outbox[3].payload!) as Map<String, Object?>;
    expect(medication['name'], 'Med B');
    expect(medication['profile_id'], ids.profile);
    expect(medication['privacy'], 'shared');
    expect(medication.containsKey('client_updated_at'), isFalse);
    for (final id in [ids.profile, ids.medication, ids.schedule]) {
      expect(id, matches(_uuidPattern));
    }
  });

  test('the stock baseline is stamped on a count and kept on other edits',
      () async {
    final ids = await env.seedLocal();
    final counted = env.clock.now;
    var row = (await env.medications.find(ids.medication))!;
    expect(row.stockSetAt, isNull, reason: 'stock not tracked');

    await env.medications.update(
      ids.medication,
      const MedicationDraft(
        name: 'Med A',
        stockCount: '30',
        stockUnit: 'tablet',
      ),
    );
    row = (await env.medications.find(ids.medication))!;
    expect(row.stockSetAt, counted.microsecondsSinceEpoch);
    final payload =
        jsonDecode((await env.outbox()).last.payload!) as Map<String, Object?>;
    expect(payload['stock_set_at'], counted.toIso8601String());

    env.clock.advance(const Duration(days: 2));
    final kept = MedicationDraft.fromRow(row);
    await env.medications.update(
      ids.medication,
      MedicationDraft(
        name: kept.name,
        notes: 'after meals',
        stockCount: kept.stockCount,
        stockUnit: kept.stockUnit,
        stockSetAt: kept.stockSetAt,
      ),
    );
    row = (await env.medications.find(ids.medication))!;
    expect(row.notes, 'after meals');
    expect(row.stockSetAt, counted.microsecondsSinceEpoch);

    await env.medications.setStock(ids.medication, '60');
    row = (await env.medications.find(ids.medication))!;
    expect(row.stockCount, '60');
    expect(row.stockUnit, 'tablet');
    expect(row.stockSetAt, env.clock.now.microsecondsSinceEpoch);

    await env.medications
        .update(ids.medication, const MedicationDraft(name: 'Med A'));
    row = (await env.medications.find(ids.medication))!;
    expect(row.stockSetAt, isNull, reason: 'tracking switched off');
  });

  test('a failed write leaves neither row nor outbox entry', () async {
    await expectLater(
      env.medications.create(
        profileId: 'missing',
        draft: const MedicationDraft(name: 'X'),
      ),
      throwsA(isA<DataException>()
          .having((e) => e.code, 'code', DataException.parentNotFound)),
    );
    expect(await env.outbox(), isEmpty);
    expect(await env.db.select(env.db.medications).get(), isEmpty);
  });

  test('conflict keys strictly increase even if the clock goes back', () async {
    final ids = await env.seedLocal();
    final first = (await env.medications.find(ids.medication))!;
    env.clock.advance(const Duration(hours: -2));
    await env.medications
        .update(ids.medication, const MedicationDraft(name: 'B'));
    await env.medications
        .update(ids.medication, const MedicationDraft(name: 'C'));
    final keys = [
      for (final e in await env.outbox())
        if (e.entityId == ids.medication) e.clientUpdatedAt,
    ];
    expect(keys, [
      first.clientUpdatedAt,
      first.clientUpdatedAt + 1,
      first.clientUpdatedAt + 2,
    ]);
    final row = (await env.medications.find(ids.medication))!;
    expect(row.clientUpdatedAt, first.clientUpdatedAt + 2);
    expect(row.updatedByDevice, await env.syncState.deviceId());
  });

  test('schedule rules are validated and stored canonically', () async {
    final ids = await env.seedLocal();
    await expectLater(
      env.schedules.create(
        medicationId: ids.medication,
        rule: {'v': 2, 'kind': 'daily'},
      ),
      throwsA(isA<DataException>()
          .having((e) => e.code, 'code', DataException.invalidRule)),
    );
    final row = (await env.schedules.find(ids.schedule))!;
    expect(row.scheduleRule.kind, RuleKind.daily);
    expect(
      jsonDecode(row.rule),
      ScheduleRule.fromJson(dailyRule()).toJson(),
    );
  });

  test('deleting a profile tombstones its medications and schedules', () async {
    final ids = await env.seedLocal();
    await env.profiles.delete(ids.profile);
    expect((await env.profiles.find(ids.profile))!.deletedAt, isNotNull);
    expect((await env.medications.find(ids.medication))!.deletedAt, isNotNull);
    expect((await env.schedules.find(ids.schedule))!.deletedAt, isNotNull);
    expect(await env.profiles.watchAll().first, isEmpty);
    final last = (await env.outbox()).last;
    expect('${last.entityKind}:${last.op}', 'profile:delete');
    await expectLater(
      env.medications.update(ids.medication, const MedicationDraft(name: 'Z')),
      throwsA(isA<DataException>()
          .having((e) => e.code, 'code', DataException.deleted)),
    );
  });

  test('the self profile cannot be deleted', () async {
    const selfId = '0b9a3c5e-1d2f-4a6b-8c7d-9e0f1a2b3c4d';
    await env.db.into(env.db.profiles).insert(
          ProfileRow(
            id: selfId,
            kind: 'self',
            displayName: 'Me',
            timezone: 'Europe/Samara',
            clientUpdatedAt: env.clock.now.microsecondsSinceEpoch,
            updatedByDevice: 'server-device',
          ),
        );
    await expectLater(
      env.profiles.delete(selfId),
      throwsA(isA<DataException>()
          .having((e) => e.code, 'code', DataException.selfProfileProtected)),
    );
  });

  group('dose events', () {
    test('use the engine occurrence key and are idempotent by id', () async {
      final ids = await env.seedLocal();
      final occurrence = OccurrenceRef(
        scheduleId: ids.schedule,
        localDate: LocalDate(2026, 10, 16),
        localTime: '08:00',
      );
      final at = DateTime.utc(2026, 10, 16, 4, 5, 6, 7, 8);
      Future<String> take() => env.doseEvents.record(
            id: 'b7c6a0de-5f1e-4b8a-9c0d-1e2f3a4b5c6d',
            medicationId: ids.medication,
            type: DoseEventType.taken,
            at: at,
            occurrence: occurrence,
          );
      final id = await take();
      expect(await take(), id);

      final events = [
        for (final e in await env.outbox())
          if (e.entityKind == 'dose_event') e,
      ];
      expect(events, hasLength(1));
      final payload =
          jsonDecode(events.single.payload!) as Map<String, Object?>;
      expect(payload['occurrence_key'], '${ids.schedule}/2026-10-16T08:00');
      expect(
        payload['occurrence_key'],
        occurrenceKey(ids.schedule, LocalDate(2026, 10, 16), '08:00'),
      );
      expect(payload['at'], '2026-10-16T04:05:06.007008Z');
      expect(payload['type'], 'taken');

      await expectLater(
        env.doseEvents.record(
          id: id,
          medicationId: ids.medication,
          type: DoseEventType.skipped,
          at: at,
        ),
        throwsA(isA<DataException>().having(
          (e) => e.code,
          'code',
          DataException.idempotencyConflict,
        )),
      );
    });

    test('undo targets a non-undo event of the same medication', () async {
      final ids = await env.seedLocal();
      final taken = await env.doseEvents.record(
        medicationId: ids.medication,
        type: DoseEventType.taken,
        at: env.clock.now,
      );
      final undo = await env.doseEvents.undo(
        targetEventId: taken,
        at: env.clock.now,
      );
      final row = (await env.doseEvents.find(undo))!;
      expect(row.eventType, 'undo');
      expect(row.targetEventId, taken);
      await expectLater(
        env.doseEvents.undo(targetEventId: undo, at: env.clock.now),
        throwsA(isA<DataException>()
            .having((e) => e.code, 'code', DataException.invalidUndoTarget)),
      );
    });

    test('an occurrence of another medication is refused', () async {
      final ids = await env.seedLocal();
      final other = await env.medications.create(
        profileId: ids.profile,
        draft: const MedicationDraft(name: 'Other'),
      );
      await expectLater(
        env.doseEvents.record(
          medicationId: other,
          type: DoseEventType.taken,
          at: env.clock.now,
          occurrence: OccurrenceRef(
            scheduleId: ids.schedule,
            localDate: LocalDate(2026, 10, 16),
            localTime: '08:00',
          ),
        ),
        throwsA(isA<DataException>().having(
          (e) => e.code,
          'code',
          DataException.invalidOccurrenceKey,
        )),
      );
    });

    test('a mark already in effect and a done undo are not repeated', () async {
      final ids = await env.seedLocal();
      final occurrence = OccurrenceRef(
        scheduleId: ids.schedule,
        localDate: LocalDate(2026, 10, 16),
        localTime: '08:00',
      );
      Future<String?> mark(DoseEventType type) => env.doseEvents.recordMark(
            medicationId: ids.medication,
            type: type,
            at: env.clock.now,
            occurrence: occurrence,
            isApplied: (events) => events.any((e) => e.eventType == type.wire),
          );
      final taken = await mark(DoseEventType.taken);
      expect(taken, isNotNull);
      expect(await mark(DoseEventType.taken), isNull);

      Future<String?> undo() =>
          env.doseEvents.undoOnce(targetEventId: taken!, at: env.clock.now);
      expect(await undo(), isNotNull);
      expect(await undo(), isNull);
      final rows = await env.db.select(env.db.doseEvents).get();
      expect(rows.map((e) => e.eventType), ['taken', 'undo']);
    });

    test('a legacy undo without a key still cancels the mark', () async {
      final ids = await env.seedLocal();
      final occurrence = OccurrenceRef(
        scheduleId: ids.schedule,
        localDate: LocalDate(2026, 10, 16),
        localTime: '08:00',
      );
      bool applied(List<DoseEventRow> events) {
        return effectiveMark(events)?.type == DoseEventType.taken;
      }

      Future<String?> take() => env.doseEvents.recordMark(
            medicationId: ids.medication,
            type: DoseEventType.taken,
            at: env.clock.now,
            occurrence: occurrence,
            isApplied: applied,
          );
      final taken = await take();
      expect(taken, isNotNull);
      // An older client wrote its undo without the occurrence key
      // (docs/spec/dose-state.md section 2: an undo applies by target).
      final legacyUndo = DoseEventRow(
        id: 'legacy-undo',
        profileId: ids.profile,
        medicationId: ids.medication,
        eventType: DoseEventType.undo.wire,
        at: env.clock.now.microsecondsSinceEpoch,
        targetEventId: taken,
      );
      await env.db.into(env.db.doseEvents).insert(legacyUndo);
      expect(await take(), isNotNull);
    });

    test('days load scheduled events by key and intakes by time', () async {
      final ids = await env.seedLocal();
      OccurrenceRef on(int day) => OccurrenceRef(
            scheduleId: ids.schedule,
            localDate: LocalDate(2026, 10, day),
            localTime: '08:00',
          );
      // The Oct 2 dose marked a week late, an Oct 9 dose, and intakes on
      // Oct 2 and Oct 9.
      final late = await env.doseEvents.record(
        medicationId: ids.medication,
        type: DoseEventType.taken,
        at: DateTime.utc(2026, 10, 9, 6),
        occurrence: on(2),
      );
      await env.doseEvents.record(
        medicationId: ids.medication,
        type: DoseEventType.taken,
        at: DateTime.utc(2026, 10, 9, 6, 1),
        occurrence: on(9),
      );
      final intake = await env.doseEvents.record(
        medicationId: ids.medication,
        type: DoseEventType.taken,
        at: DateTime.utc(2026, 10, 2, 12),
      );
      await env.doseEvents.record(
        medicationId: ids.medication,
        type: DoseEventType.taken,
        at: DateTime.utc(2026, 10, 9, 12),
      );

      final events = await env.doseEvents.watchForDays(
        scheduleIds: [ids.schedule],
        firstDay: LocalDate(2026, 10, 2),
        lastDay: LocalDate(2026, 10, 2),
        from: DateTime.utc(2026, 10, 2),
        to: DateTime.utc(2026, 10, 3),
      ).first;

      expect(events.map((e) => e.id), [intake, late]);
    });
  });

  group('schedule history (ADR 0003)', () {
    Future<Map<String, Object?>> ruleOf(String id) async =>
        jsonDecode((await env.schedules.find(id))!.rule)
            as Map<String, Object?>;

    test('a split ends the old schedule and continues with a new one',
        () async {
      final ids = await env.seedLocal();
      final next = await env.schedules.split(
        ids.schedule,
        endDate: LocalDate(2026, 10, 15),
        rule: {...dailyRule(time: '09:00'), 'start_date': '2026-10-16'},
      );

      final old = await ruleOf(ids.schedule);
      expect(old['end_date'], '2026-10-15');
      expect((old['times']! as List<Object?>).length, 1);
      final created = await env.schedules.find(next);
      expect(created?.medicationId, ids.medication);
      expect((await ruleOf(next))['start_date'], '2026-10-16');
      final outbox = await env.outbox();
      expect(
        outbox.reversed.take(2).map((e) => '${e.entityId}:${e.op}'),
        ['$next:upsert', '${ids.schedule}:upsert'],
      );
    });

    test('finishing a medication ends running and drops future schedules',
        () async {
      final ids = await env.seedLocal();
      final future = await env.schedules.create(
        medicationId: ids.medication,
        rule: {...dailyRule(), 'start_date': '2026-10-20'},
      );
      final ended = await env.schedules.create(
        medicationId: ids.medication,
        rule: {...dailyRule(), 'end_date': '2026-10-05'},
      );

      await env.schedules.finishMedication(
        ids.medication,
        LocalDate(2026, 10, 16),
      );

      expect((await ruleOf(ids.schedule))['end_date'], '2026-10-15');
      expect((await env.schedules.find(future))?.deletedAt, isNotNull);
      expect((await ruleOf(ended))['end_date'], '2026-10-05');
      expect((await env.schedules.find(ended))?.deletedAt, isNull);
      expect((await env.medications.find(ids.medication))?.deletedAt, isNull);
    });
  });
}
