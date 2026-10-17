import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/sync_dto.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/data/repositories/schedules_repository.dart';
import 'package:pillpal/src/data/sync/server_state_applier.dart';

import 'scope_fixtures.dart';
import 'sync_fixtures.dart';
import 'test_env.dart';

// Rules of ADR 0006 §7 for entities of other people's scopes.

const String _profile = 'rel-profile';
const String _medication = 'rel-medication';
const String _schedule = 'rel-schedule';

EntityState _upsert(Map<String, Object?> data, {DateTime? key}) => EntityState(
      op: SyncOp.upsert,
      data: data,
      clientUpdatedAt: key,
      updatedByDevice: null, // projected roles never see the device
      deletedAt: null,
    );

const EntityState _delete = EntityState(
  op: SyncOp.delete,
  data: null,
  clientUpdatedAt: null,
  updatedByDevice: null,
  deletedAt: null,
);

Map<String, Object?> _sharedMedication() =>
    medicationOut(_profile, name: 'Shared med');

Map<String, Object?> _event(String note) => {
      'profile_id': _profile,
      'medication_id': _medication,
      'type': 'taken',
      'at': '2026-10-16T08:00:00Z',
      'occurrence_key': '$_schedule/2026-10-16T08:00',
      'target_event_id': null,
      'note': note,
      'recorded_at': '2026-10-16T08:00:01Z',
      'device_id': 'dev',
      'snooze_until': null,
    };

void main() {
  late TestEnv env;
  late ServerStateApplier applier;
  final key = DateTime.utc(2026, 10, 16, 9);

  setUp(() async {
    env = await TestEnv.create();
    applier = ServerStateApplier(env.db);
  });
  tearDown(() => env.dispose());

  Future<void> apply(
    SyncEntity entity,
    String id,
    EntityState state, {
    String role = ScopeRole.viewer,
    bool overridePending = false,
  }) {
    return env.db.transaction(
      () => applier.apply(
        entity,
        id,
        state,
        role: role,
        overridePending: overridePending,
      ),
    );
  }

  Future<void> seedShared({String role = ScopeRole.editor}) async {
    await apply(
      SyncEntity.profile,
      _profile,
      _upsert(
        {'kind': 'self', 'display_name': 'Rel', 'timezone': 'Europe/Berlin'},
        key: key,
      ),
      role: role,
    );
    await apply(
      SyncEntity.medication,
      _medication,
      _upsert(_sharedMedication(), key: key),
      role: role,
    );
    await apply(
      SyncEntity.schedule,
      _schedule,
      _upsert({'medication_id': _medication, 'rule': dailyRule()}, key: key),
      role: role,
    );
  }

  test('a projected row without a device or key is stored', () async {
    await apply(
      SyncEntity.medication,
      _medication,
      _upsert(_sharedMedication(), key: key),
    );
    final row = (await env.medications.find(_medication))!;
    expect(row.name, 'Shared med');
    expect(row.redacted, isFalse);
    expect(row.updatedByDevice, '');
    expect(row.clientUpdatedAt, key.microsecondsSinceEpoch);
  });

  test('a redacted medication has no name and no private fields', () async {
    await apply(
      SyncEntity.medication,
      _medication,
      _upsert(redactedMedication(_profile)),
    );
    final row = (await env.medications.find(_medication))!;
    expect(row.redacted, isTrue);
    expect(row.name, isNull);
    expect(row.notes, isNull);
    expect(row.stockCount, isNull);
    expect(row.privacy, 'anonymous');
    expect(row.clientUpdatedAt, 0);
  });

  test('a redacted schedule has the placeholder dose, never the real one',
      () async {
    await apply(
      SyncEntity.schedule,
      _schedule,
      _upsert(redactedSchedule(_medication, time: '09:30')),
    );
    final row = (await env.schedules.find(_schedule))!;
    expect(row.redacted, isTrue);
    expect(row.rule, isNot(contains('dose')));
    final rule = row.scheduleRule;
    expect(rule.times.single.time, '09:30');
    expect(rule.times.single.dose.amount, '1');
  });

  test('a delete is a hard delete of the entity and its children', () async {
    await seedShared();
    await env.db.into(env.db.doseEvents).insert(
          DoseEventRow(
            id: 'e1',
            profileId: _profile,
            medicationId: _medication,
            eventType: 'taken',
            at: key.microsecondsSinceEpoch,
          ),
        );

    await apply(SyncEntity.medication, _medication, _delete);

    expect(await env.medications.find(_medication), isNull, reason: 'no tomb');
    expect(await env.schedules.find(_schedule), isNull);
    expect(await env.db.select(env.db.doseEvents).get(), isEmpty);
    expect(await env.profiles.find(_profile), isNotNull);
  });

  test('a profile delete evicts the whole scope', () async {
    await seedShared();
    await env.db.into(env.db.accessScopes).insert(
          AccessScopesCompanion.insert(
            profileId: _profile,
            role: ScopeRole.editor,
            kind: 'self',
          ),
        );

    await apply(SyncEntity.profile, _profile, _delete);

    expect(await env.profiles.find(_profile), isNull);
    expect(await env.medications.find(_medication), isNull);
    expect(await env.access.scope(_profile), isNull);
  });

  test('dose events are overwritten, so a stripped note replaces a stored one',
      () async {
    await apply(SyncEntity.doseEvent, 'e1', _upsert(_event('private')));
    await apply(SyncEntity.doseEvent, 'e1', _upsert(_event('')));
    final row = (await env.db.select(env.db.doseEvents).getSingle());
    expect(row.note, '');

    await apply(
      SyncEntity.doseEvent,
      'e1',
      _upsert({..._event('x'), 'note': null, 'device_id': null}),
    );
    final stripped = await env.db.select(env.db.doseEvents).getSingle();
    expect(stripped.note, isNull);
    expect(stripped.deviceId, isNull);
  });

  group('projected rows override pending local edits', () {
    test('a redacted row replaces the entity and drops its pending entries',
        () async {
      await seedShared();
      await env.medications
          .update(_medication, const MedicationDraft(name: 'My edit'));
      await env.schedules.update(_schedule, dailyRule(time: '10:00'));
      expect(await env.outbox(), hasLength(2));

      await apply(
        SyncEntity.medication,
        _medication,
        _upsert(redactedMedication(_profile)),
        role: ScopeRole.editor,
      );

      final row = (await env.medications.find(_medication))!;
      expect(row.name, isNull);
      expect(row.redacted, isTrue);
      // The pending schedule edit was a child of the narrowed medication.
      expect(await env.outbox(), isEmpty);
    });

    test('a changed privacy level overrides, an unchanged one does not',
        () async {
      await seedShared();
      await env.medications
          .update(_medication, const MedicationDraft(name: 'My edit'));

      await apply(
        SyncEntity.medication,
        _medication,
        _upsert(
          medicationOut(_profile, name: 'Server name'),
          key: key.add(const Duration(minutes: 1)),
        ),
        role: ScopeRole.editor,
      );
      expect(
        (await env.medications.find(_medication))!.name,
        'My edit',
        reason: 'same privacy: last-write-wins decides on push',
      );
      expect(await env.outbox(), hasLength(1));

      await env.db.update(env.db.medications).write(
            const MedicationsCompanion(privacy: Value('anonymous')),
          );
      await apply(
        SyncEntity.medication,
        _medication,
        _upsert(medicationOut(_profile, name: 'Server name'), key: key),
        role: ScopeRole.editor,
      );
      expect((await env.medications.find(_medication))!.name, 'Server name');
      expect(await env.outbox(), isEmpty);
    });

    test('a guardian keeps last-write-wins for ordinary rows', () async {
      await seedShared(role: ScopeRole.guardian);
      await env.medications
          .update(_medication, const MedicationDraft(name: 'My edit'));

      await apply(
        SyncEntity.medication,
        _medication,
        _upsert(medicationOut(_profile, name: 'Theirs'), key: key),
        role: ScopeRole.guardian,
      );

      expect((await env.medications.find(_medication))!.name, 'My edit');
    });

    test('an explicit override (current of a refused push) wins', () async {
      await seedShared();
      await env.medications
          .update(_medication, const MedicationDraft(name: 'My edit'));

      await apply(
        SyncEntity.medication,
        _medication,
        _upsert(medicationOut(_profile, name: 'Server name'), key: key),
        role: ScopeRole.editor,
        overridePending: true,
      );

      expect((await env.medications.find(_medication))!.name, 'Server name');
      expect(await env.outbox(), isEmpty);
    });
  });

  test('a projected profile keeps the alert settings it does not carry',
      () async {
    await apply(
      SyncEntity.profile,
      _profile,
      _upsert(
        {
          'kind': 'managed',
          'display_name': 'Full',
          'timezone': 'UTC',
          'missed_alert_minutes': 45,
          'missed_alerts_enabled': false,
        },
        key: key,
      ),
      role: ScopeRole.guardian,
    );
    await apply(
      SyncEntity.profile,
      _profile,
      _upsert(
        {'kind': 'managed', 'display_name': 'Renamed', 'timezone': 'UTC'},
        key: key,
      ),
      role: ScopeRole.editor,
    );

    final row = (await env.profiles.find(_profile))!;
    expect(row.displayName, 'Renamed');
    expect(row.missedAlertMinutes, 45);
    expect(row.missedAlertsEnabled, isFalse);
  });

  test('a new profile without alert settings gets the server defaults',
      () async {
    await apply(
      SyncEntity.profile,
      _profile,
      _upsert(
        {'kind': 'self', 'display_name': 'Rel', 'timezone': 'UTC'},
        key: key,
      ),
    );
    final row = (await env.profiles.find(_profile))!;
    expect(row.missedAlertMinutes, 30);
    expect(row.missedAlertsEnabled, isTrue);
  });
}
