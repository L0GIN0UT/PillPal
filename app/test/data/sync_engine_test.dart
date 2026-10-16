import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/data/sync/sync_status.dart';

import 'fake_server.dart';
import 'test_env.dart';

Json _rejected(Json m, String code, {Json? current}) => {
      'entity': m['entity'],
      'id': m['id'],
      'status': 'rejected',
      'code': code,
      'version': null,
      'current': current,
    };

void main() {
  late TestEnv env;

  setUp(() => env = TestEnv());
  tearDown(() => env.dispose());

  group('push', () {
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
        data: {..._medicationOut(ids.profile), 'name': 'Server name'},
        key: serverKey,
      );
      await env.medications
          .update(ids.medication, const MedicationDraft(name: 'Local'));

      final report = await env.engine.sync();

      expect(report.adopted, 1);
      final row = (await env.medications.find(ids.medication))!;
      expect(row.name, 'Server name');
      expect(row.clientUpdatedAt, serverKey.microsecondsSinceEpoch);
      expect(row.updatedByDevice, 'other-device');
      expect(await env.outbox(), isEmpty);

      // The next local edit must beat the adopted key.
      await env.medications
          .update(ids.medication, const MedicationDraft(name: 'Again'));
      final entry = (await env.outbox()).single;
      expect(entry.clientUpdatedAt, serverKey.microsecondsSinceEpoch + 1);
    });

    test('ignored_stale on a tombstone deletes locally with children',
        () async {
      final ids = await env.seedLocal();
      await env.engine.sync();
      env.server.seed('medication', ids.medication,
          key: env.clock.now, deleted: true);
      env.clock.advance(const Duration(minutes: 1));
      await env.medications
          .update(ids.medication, const MedicationDraft(name: 'Edit'));

      await env.engine.sync();

      expect(
          (await env.medications.find(ids.medication))!.deletedAt, isNotNull);
      expect((await env.schedules.find(ids.schedule))!.deletedAt, isNotNull);
      expect(await env.outbox(), isEmpty);
    });

    test('key_conflict adopts current; parent_deleted drops the entity',
        () async {
      final ids = await env.seedLocal();
      env.server.responder = (m) {
        if (m['entity'] == 'medication') {
          return _rejected(m, 'key_conflict', current: {
            'op': 'upsert',
            'data': {..._medicationOut(ids.profile), 'name': 'Winner'},
            'client_updated_at': '2026-10-16T09:00:00.000001Z',
            'updated_by_device': 'zz-device',
            'deleted_at': null,
          });
        }
        if (m['entity'] == 'schedule') {
          return _rejected(m, 'parent_deleted');
        }
        return null;
      };

      final report = await env.engine.sync();

      expect(report.ok, isTrue);
      expect(report.adopted, 2);
      expect((await env.medications.find(ids.medication))!.name, 'Winner');
      expect((await env.schedules.find(ids.schedule))!.deletedAt, isNotNull);
      expect(await env.outbox(), isEmpty);
    });

    test('clock_skew keeps the entry, stops pushing and reports', () async {
      final ids = await env.seedLocal();
      env.server.responder =
          (m) => m['entity'] == 'profile' ? _rejected(m, 'clock_skew') : null;

      final report = await env.engine.sync();

      expect(report.errorCode, 'clock_skew');
      expect(env.engine.status.phase, SyncPhase.error);
      expect(env.engine.status.errorCode, 'clock_skew');
      expect(env.server.pushes, hasLength(1));
      final kept = (await env.outbox()).single;
      expect(kept.entityId, ids.profile);
      expect(kept.attempts, 1);
      expect(kept.lastError, 'clock_skew');
      expect(kept.parked, isFalse);

      env.server.responder = null;
      final retry = await env.engine.sync();
      expect(retry.ok, isTrue);
      expect(await env.outbox(), isEmpty);
      expect(env.engine.status.phase, SyncPhase.idle);
    });

    test('permanent rejections are parked and not pushed again', () async {
      final ids = await env.seedLocal();
      env.server.responder = (m) =>
          m['entity'] == 'medication' ? _rejected(m, 'validation_error') : null;

      final report = await env.engine.sync();

      expect(report.ok, isTrue);
      expect(report.parked, 1);
      expect(env.engine.status.parkedCount, 1);
      final parked = (await env.outbox()).single;
      expect(parked.entityId, ids.medication);
      expect(parked.parked, isTrue);
      expect(parked.lastError, 'validation_error');

      await env.engine.sync();
      expect(env.server.pushes, hasLength(1));
    });
  });

  group('pull', () {
    test('pages until has_more is false and stores the cursor', () async {
      for (var i = 0; i < 1200; i++) {
        env.server.seed(
          'profile',
          'p-$i',
          data: {'kind': 'managed', 'display_name': 'P$i', 'timezone': 'UTC'},
          key: env.clock.now,
        );
      }

      final report = await env.engine.sync();

      expect(report.pulled, 1200);
      expect(await env.syncState.cursor(), 1200);
      expect(
        [
          for (final r in env.server.requests)
            if (r.path == '/v1/sync/pull') r.query['cursor'],
        ],
        ['0', '500', '1000'],
      );
      expect(await env.db.select(env.db.profiles).get(), hasLength(1200));
    });

    test('a failed page keeps the applied pages and their cursor', () async {
      for (var i = 0; i < 700; i++) {
        env.server.seed(
          'profile',
          'p-$i',
          data: {'kind': 'managed', 'display_name': 'P$i', 'timezone': 'UTC'},
          key: env.clock.now,
        );
      }
      env.server.failPullAtCursor = 500;

      final report = await env.engine.sync();

      expect(report.errorCode, 'unavailable');
      expect(env.engine.status.phase, SyncPhase.error);
      expect(await env.syncState.cursor(), 500);
      expect(await env.db.select(env.db.profiles).get(), hasLength(500));

      env.server.failPullAtCursor = null;
      await env.engine.sync();
      expect(await env.syncState.cursor(), 700);
      expect(env.engine.status.lastSuccessAt, env.clock.now);
    });

    test('tombstones delete locally, children included', () async {
      final ids = await env.seedLocal();
      await env.engine.sync();
      env.server
          .seed('profile', ids.profile, key: env.clock.now, deleted: true);

      await env.engine.sync();

      expect((await env.profiles.find(ids.profile))!.deletedAt, isNotNull);
      expect(
          (await env.medications.find(ids.medication))!.deletedAt, isNotNull);
      expect((await env.schedules.find(ids.schedule))!.deletedAt, isNotNull);
    });

    test('dose events are inserted once and learn recorded_at', () async {
      final ids = await env.seedLocal();
      final id = await env.doseEvents.record(
        medicationId: ids.medication,
        type: DoseEventType.taken,
        at: env.clock.now,
      );
      await env.engine.sync();
      await env.engine.sync();

      final rows = await env.db.select(env.db.doseEvents).get();
      expect(rows, hasLength(1));
      expect(rows.single.id, id);
      expect(rows.single.recordedAt, isNotNull);
    });
  });

  test('sync is single-flight', () async {
    await env.seedLocal();
    final first = env.engine.sync();
    final second = env.engine.sync();
    expect(identical(first, second), isTrue);
    await first;
    expect(env.server.pushes, hasLength(1));
    final third = env.engine.sync();
    expect(identical(first, third), isFalse);
    await third;
  });

  test('signed out: nothing is sent', () async {
    final signedOut = TestEnv(signedIn: false);
    addTearDown(signedOut.dispose);
    await signedOut.seedLocal();
    final report = await signedOut.engine.sync();
    expect(report.signedOut, isTrue);
    expect(signedOut.server.requests, isEmpty);
    expect(signedOut.engine.status.phase, SyncPhase.idle);
  });

  test('two devices converge on last-write-wins', () async {
    final other = TestEnv(server: env.server);
    addTearDown(other.dispose);
    final ids = await env.seedLocal();
    await env.engine.sync();
    await other.engine.sync();
    expect((await other.medications.find(ids.medication))!.name, 'Med A');

    await env.medications
        .update(ids.medication, const MedicationDraft(name: 'Early'));
    other.clock.advance(const Duration(seconds: 30));
    await other.medications
        .update(ids.medication, const MedicationDraft(name: 'Late'));
    await other.engine.sync();
    await env.engine.sync();
    await other.engine.sync();

    expect((await env.medications.find(ids.medication))!.name, 'Late');
    expect((await other.medications.find(ids.medication))!.name, 'Late');
    expect(env.server.dataOf('medication', ids.medication)!['name'], 'Late');
  });
}

Json _medicationOut(String profileId) => {
      'profile_id': profileId,
      'name': 'Med A',
      'form': null,
      'strength_text': null,
      'notes': null,
      'tz_mode': 'local',
      'fixed_tz': null,
      'stock_count': null,
      'stock_unit': null,
      'low_stock_days': null,
      'privacy': 'shared',
      'version': 2,
      'created_at': '2026-10-16T09:00:00Z',
      'updated_at': '2026-10-16T09:00:00Z',
    };
