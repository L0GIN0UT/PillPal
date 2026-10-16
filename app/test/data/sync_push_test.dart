import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/data/sync/sync_status.dart';

import 'fake_server.dart';
import 'sync_fixtures.dart';
import 'test_env.dart';

void main() {
  late TestEnv env;

  setUp(() => env = TestEnv());
  tearDown(() => env.dispose());

  test('sends the outbox in order, in batches of 500', () async {
    final ids = await env.seedLocal();
    for (var i = 0; i < 520; i++) {
      await env.doseEvents.record(
        medicationId: ids.medication,
        type: DoseEventType.taken,
        at: env.clock.now.subtract(Duration(minutes: i)),
      );
    }
    final expected = [for (final e in await env.outbox()) e.entityId];

    final report = await env.engine.sync();

    expect(report.ok, isTrue);
    expect(report.pushed, 523);
    expect(env.server.pushes.map((batch) => batch.length), [500, 23]);
    expect(
      [for (final batch in env.server.pushes) ...batch.map((m) => m['id'])],
      expected,
    );
    expect(await env.outbox(), isEmpty);
    expect(env.server.dataOf('medication', ids.medication)!['name'], 'Med A');
    final push =
        env.server.requests.firstWhere((r) => r.path == '/v1/sync/push');
    expect(push.headers['x-device-id'], await env.syncState.deviceId());
  });

  test('ignored_stale adopts the newer server state', () async {
    final ids = await env.seedLocal();
    await env.engine.sync();
    final serverKey = env.clock.now.add(const Duration(minutes: 5));
    env.server.seed(
      'medication',
      ids.medication,
      data: medicationOut(ids.profile, name: 'Server name'),
      key: serverKey,
    );
    await env.medications.update(
      ids.medication,
      const MedicationDraft(name: 'Local'),
    );

    final report = await env.engine.sync();

    expect(report.adopted, 1);
    final row = (await env.medications.find(ids.medication))!;
    expect(row.name, 'Server name');
    expect(row.clientUpdatedAt, serverKey.microsecondsSinceEpoch);
    expect(row.updatedByDevice, 'other-device');
    expect(await env.outbox(), isEmpty);

    // The next local edit must beat the adopted key.
    await env.medications.update(
      ids.medication,
      const MedicationDraft(name: 'Again'),
    );
    final entry = (await env.outbox()).single;
    expect(entry.clientUpdatedAt, serverKey.microsecondsSinceEpoch + 1);
  });

  test('ignored_stale on a tombstone deletes locally with children', () async {
    final ids = await env.seedLocal();
    await env.engine.sync();
    env.server.seed(
      'medication',
      ids.medication,
      key: env.clock.now,
      deleted: true,
    );
    env.clock.advance(const Duration(minutes: 1));
    await env.medications.update(
      ids.medication,
      const MedicationDraft(name: 'Edit'),
    );

    await env.engine.sync();

    expect((await env.medications.find(ids.medication))!.deletedAt, isNotNull);
    expect((await env.schedules.find(ids.schedule))!.deletedAt, isNotNull);
    expect(await env.outbox(), isEmpty);
  });

  test('the server emits key_conflict for a reused key; current is adopted',
      () async {
    final ids = await env.seedLocal();
    await env.engine.sync();
    final stored = (await env.medications.find(ids.medication))!;
    await env.db.into(env.db.outbox).insert(
          OutboxCompanion.insert(
            entityKind: 'medication',
            op: 'upsert',
            entityId: ids.medication,
            payload: Value(
              jsonEncode({
                ...medicationOut(ids.profile, name: 'Same key, other data'),
              }..removeWhere(
                  (k, _) => const {'version', 'created_at', 'updated_at'}
                      .contains(k),
                )),
            ),
            clientUpdatedAt: stored.clientUpdatedAt,
          ),
        );

    final report = await env.engine.sync();

    expect(report.adopted, 1);
    expect((await env.medications.find(ids.medication))!.name, 'Med A');
    expect(await env.outbox(), isEmpty);
  });

  test('parent_deleted, or parent_not_found under a local tombstone, drops',
      () async {
    final ids = await env.seedLocal();
    await env.profiles.delete(ids.profile);
    env.server.responder = (m) => switch (m['entity']) {
          'medication' => rejected(m, 'parent_not_found'),
          'schedule' => rejected(m, 'parent_deleted'),
          _ => null,
        };

    final report = await env.engine.sync();

    expect(report.ok, isTrue);
    expect(report.adopted, 2);
    expect(report.parked, 0);
    expect((await env.medications.find(ids.medication))!.deletedAt, isNotNull);
    expect((await env.schedules.find(ids.schedule))!.deletedAt, isNotNull);
    expect(await env.outbox(), isEmpty);
  });

  test('clock_skew stops result handling; the rest of the batch stays',
      () async {
    final ids = await env.seedLocal();
    env.server.responder =
        (m) => m['entity'] == 'profile' ? rejected(m, 'clock_skew') : null;

    final report = await env.engine.sync();

    expect(report.errorCode, 'clock_skew');
    expect(env.engine.status.phase, SyncPhase.error);
    expect(env.engine.status.errorCode, 'clock_skew');
    final kept = await env.outbox();
    expect(
      kept.map((e) => e.entityId),
      [ids.profile, ids.medication, ids.schedule],
    );
    expect(kept.first.lastError, 'clock_skew');
    expect(kept.first.parked, isFalse);
    expect(kept[1].attempts, 0, reason: 'child result was not processed');
    expect(kept[1].parked, isFalse);

    env.server.responder = null;
    final retry = await env.engine.sync();
    expect(retry.ok, isTrue);
    expect(await env.outbox(), isEmpty);
    expect(env.server.dataOf('schedule', ids.schedule), isNotNull);
    expect(env.engine.status.phase, SyncPhase.idle);
  });

  test('a device clock ahead of the server is corrected and re-keyed',
      () async {
    final serverTime = FakeClock(DateTime.utc(2026, 10, 16, 9));
    final skewed = TestEnv(server: FakeServer(now: serverTime.call));
    addTearDown(skewed.dispose);
    skewed.clock.advance(const Duration(hours: 1));
    final ids = await skewed.seedLocal();
    final event = await skewed.doseEvents.record(
      medicationId: ids.medication,
      type: DoseEventType.taken,
      at: skewed.clock.now,
    );

    final report = await skewed.engine.sync();

    expect(report.ok, isTrue);
    expect(await skewed.outbox(), isEmpty);
    expect(skewed.serverClock.offset, const Duration(hours: -1));
    final row = (await skewed.medications.find(ids.medication))!;
    expect(
      row.clientUpdatedAt,
      lessThan(serverTime.now.add(const Duration(seconds: 1)).microsecondsSinceEpoch),
    );
    final at = DateTime.parse(
      skewed.server.dataOf('dose_event', event)!['at']! as String,
    );
    expect(at, serverTime.now);

    await skewed.medications.update(
      ids.medication,
      const MedicationDraft(name: 'Later'),
    );
    expect(
      (await skewed.outbox()).single.clientUpdatedAt,
      row.clientUpdatedAt + 1,
    );
  });

  group('permanent rejections', () {
    test('a rejected create is deleted locally and parked', () async {
      final ids = await env.seedLocal();
      env.server.responder = (m) =>
          m['entity'] == 'medication' ? rejected(m, 'validation_error') : null;

      final report = await env.engine.sync();

      expect(report.ok, isTrue);
      expect(report.parked, 2, reason: 'the schedule lost its parent');
      expect(env.engine.status.parkedCount, 2);
      expect(
        (await env.medications.find(ids.medication))!.deletedAt,
        isNotNull,
      );
      expect((await env.schedules.find(ids.schedule))!.deletedAt, isNotNull);
      final parked = await env.outbox();
      expect(parked.map((e) => e.lastError), [
        'validation_error',
        'parent_not_found',
      ]);
      expect(parked.every((e) => e.parked), isTrue);

      await env.engine.sync();
      expect(env.server.pushes, hasLength(1));
    });

    test('a rejected update adopts the server state (GET)', () async {
      final ids = await env.seedLocal();
      await env.engine.sync();
      await env.medications.update(
        ids.medication,
        const MedicationDraft(name: 'Rejected'),
      );
      env.server.responder = (m) =>
          m['entity'] == 'medication' ? rejected(m, 'immutable_field') : null;

      final report = await env.engine.sync();

      expect(report.parked, 1);
      final row = (await env.medications.find(ids.medication))!;
      expect(row.name, 'Med A');
      expect(row.deletedAt, isNull);
      expect(
        env.server.requests.map((r) => r.path),
        contains('/v1/medications/${ids.medication}'),
      );
    });
  });
}
