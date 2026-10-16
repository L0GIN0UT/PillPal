import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/sync_dto.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/data/sync/server_state_applier.dart';

import 'test_env.dart';

EntityState _upsert(Map<String, Object?> data, DateTime key) => EntityState(
      op: SyncOp.upsert,
      data: data,
      clientUpdatedAt: key,
      updatedByDevice: 'other-device',
      deletedAt: null,
    );

Map<String, Object?> _medication(String profileId, String name) => {
      'profile_id': profileId,
      'name': name,
      'form': 'tablet',
      'strength_text': '500 mg',
      'notes': null,
      'tz_mode': 'fixed',
      'fixed_tz': 'Europe/Berlin',
      'stock_count': '12.500',
      'stock_unit': 'tablet',
      'low_stock_days': 3,
      'privacy': 'anonymous',
    };

void main() {
  late TestEnv env;
  late ServerStateApplier applier;

  setUp(() async {
    env = await TestEnv.create();
    applier = ServerStateApplier(env.db);
  });
  tearDown(() => env.dispose());

  test('an upsert creates or replaces the row with the server key', () async {
    final key = DateTime.utc(2026, 10, 16, 9, 30, 0, 0, 1);
    await applier.apply(
      SyncEntity.medication,
      'm-1',
      _upsert(_medication('p-1', 'Server'), key),
    );
    final row = (await env.medications.find('m-1'))!;
    expect(row.name, 'Server');
    expect(row.stockCount, '12.500');
    expect(row.fixedTz, 'Europe/Berlin');
    expect(row.lowStockDays, 3);
    expect(row.privacy, 'anonymous');
    expect(row.clientUpdatedAt, key.microsecondsSinceEpoch);
    expect(row.updatedByDevice, 'other-device');
  });

  test('nulls in server state clear local fields', () async {
    final key = DateTime.utc(2026, 10, 16, 9, 30);
    await applier.apply(
      SyncEntity.medication,
      'm-1',
      _upsert(_medication('p-1', 'Server'), key),
    );
    await applier.apply(
      SyncEntity.medication,
      'm-1',
      _upsert(
        {
          ..._medication('p-1', 'Server'),
          'form': null,
          'strength_text': null,
          'tz_mode': 'local',
          'fixed_tz': null,
          'stock_count': null,
          'stock_unit': null,
          'low_stock_days': null,
        },
        key.add(const Duration(seconds: 1)),
      ),
    );
    final row = (await env.medications.find('m-1'))!;
    expect(row.form, isNull);
    expect(row.strengthText, isNull);
    expect(row.fixedTz, isNull);
    expect(row.stockCount, isNull);
    expect(row.stockUnit, isNull);
    expect(row.lowStockDays, isNull);
  });

  test('a pending local mutation shields the entity from upserts', () async {
    final ids = await env.seedLocal();
    await env.medications
        .update(ids.medication, const MedicationDraft(name: 'Mine'));
    await env.db.transaction(
      () => applier.apply(
        SyncEntity.medication,
        ids.medication,
        _upsert(_medication(ids.profile, 'Theirs'), DateTime.utc(2030)),
      ),
    );
    expect((await env.medications.find(ids.medication))!.name, 'Mine');
  });

  test('a delete wins over a pending local mutation', () async {
    final ids = await env.seedLocal();
    await env.medications
        .update(ids.medication, const MedicationDraft(name: 'Mine'));
    await applier.apply(
      SyncEntity.medication,
      ids.medication,
      EntityState(
        op: SyncOp.delete,
        data: null,
        clientUpdatedAt: DateTime.utc(2026),
        updatedByDevice: 'other-device',
        deletedAt: DateTime.utc(2026, 10, 16),
      ),
    );
    final row = (await env.medications.find(ids.medication))!;
    expect(row.deletedAt, DateTime.utc(2026, 10, 16).microsecondsSinceEpoch);
    expect((await env.schedules.find(ids.schedule))!.deletedAt, isNotNull);
  });

  test('parked entries do not shield; tombstones are not resurrected',
      () async {
    final ids = await env.seedLocal();
    await env.db.customStatement('UPDATE outbox SET parked = 1');
    await applier.apply(
      SyncEntity.medication,
      ids.medication,
      _upsert(_medication(ids.profile, 'Server'), DateTime.utc(2030)),
    );
    expect((await env.medications.find(ids.medication))!.name, 'Server');

    await env.db.delete(env.db.outbox).go();
    await env.schedules.delete(ids.schedule);
    await env.db.delete(env.db.outbox).go();
    await applier.apply(
      SyncEntity.schedule,
      ids.schedule,
      _upsert(
        {'medication_id': ids.medication, 'rule': dailyRule()},
        DateTime.utc(2030),
      ),
    );
    expect((await env.schedules.find(ids.schedule))!.deletedAt, isNotNull);
  });

  test('dose events are inserted only if missing', () async {
    const state = EntityState(
      op: SyncOp.upsert,
      data: {
        'id': 'e-1',
        'profile_id': 'p-1',
        'medication_id': 'm-1',
        'occurrence_key': null,
        'type': 'skipped',
        'target_event_id': null,
        'at': '2026-10-16T08:00:00.123456Z',
        'recorded_at': '2026-10-16T08:00:01Z',
        'device_id': 'other-device',
        'note': 'Synthetic note',
      },
      clientUpdatedAt: null,
      updatedByDevice: null,
      deletedAt: null,
    );
    await applier.apply(SyncEntity.doseEvent, 'e-1', state);
    await applier.apply(SyncEntity.doseEvent, 'e-1', state);
    final rows = await env.db.select(env.db.doseEvents).get();
    expect(rows, hasLength(1));
    expect(
      rows.single.at,
      DateTime.utc(2026, 10, 16, 8, 0, 0, 123, 456).microsecondsSinceEpoch,
    );
    expect(rows.single.eventType, 'skipped');
  });

  test('an upsert without its conflict key is malformed', () async {
    await expectLater(
      applier.apply(
        SyncEntity.profile,
        'p-1',
        const EntityState(
          op: SyncOp.upsert,
          data: {'kind': 'managed', 'display_name': 'X', 'timezone': 'UTC'},
          clientUpdatedAt: null,
          updatedByDevice: null,
          deletedAt: null,
        ),
      ),
      throwsFormatException,
    );
  });
}
