import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';

// Schema version 1 as created by the first release of the data layer
// (milestone 2.1), for the tables the version 2 migration touches.
const _v1DoseEvents = '''
CREATE TABLE "dose_events" (
  "id" TEXT NOT NULL,
  "profile_id" TEXT NOT NULL,
  "medication_id" TEXT NOT NULL,
  "event_type" TEXT NOT NULL,
  "at" INTEGER NOT NULL,
  "occurrence_key" TEXT NULL,
  "target_event_id" TEXT NULL,
  "note" TEXT NULL,
  "recorded_at" INTEGER NULL,
  "device_id" TEXT NULL,
  PRIMARY KEY ("id")
)''';

// Dose events of schema version 2 (the snooze column added).
final _doseEventsV2 = _v1DoseEvents.replaceFirst(
  '"device_id" TEXT NULL,',
  '"device_id" TEXT NULL, "snooze_until" INTEGER NULL,',
);

// The medications table of schema versions 1 and 2, which the version 3
// migration touches.
const _medicationsV1V2 = '''
CREATE TABLE "medications" (
  "id" TEXT NOT NULL,
  "profile_id" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "form" TEXT NULL,
  "strength_text" TEXT NULL,
  "notes" TEXT NULL,
  "tz_mode" TEXT NOT NULL,
  "fixed_tz" TEXT NULL,
  "stock_count" TEXT NULL,
  "stock_unit" TEXT NULL,
  "low_stock_days" INTEGER NULL,
  "privacy" TEXT NOT NULL,
  "client_updated_at" INTEGER NOT NULL,
  "updated_by_device" TEXT NOT NULL,
  "deleted_at" INTEGER NULL,
  PRIMARY KEY ("id")
)''';

// Tables unchanged since schema version 1 that the version 4 migration
// reads or alters; every upgrade path runs through it.
const _unchangedSinceV1 = [
  '''
CREATE TABLE "profiles" (
  "id" TEXT NOT NULL,
  "kind" TEXT NOT NULL,
  "display_name" TEXT NOT NULL,
  "timezone" TEXT NOT NULL,
  "client_updated_at" INTEGER NOT NULL,
  "updated_by_device" TEXT NOT NULL,
  "deleted_at" INTEGER NULL,
  PRIMARY KEY ("id")
)''',
  '''
CREATE TABLE "schedules" (
  "id" TEXT NOT NULL,
  "medication_id" TEXT NOT NULL,
  "rule" TEXT NOT NULL,
  "client_updated_at" INTEGER NOT NULL,
  "updated_by_device" TEXT NOT NULL,
  "deleted_at" INTEGER NULL,
  PRIMARY KEY ("id")
)''',
  '''
CREATE TABLE "outbox" (
  "seq" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  "entity_kind" TEXT NOT NULL,
  "op" TEXT NOT NULL,
  "entity_id" TEXT NOT NULL,
  "payload" TEXT NULL,
  "client_updated_at" INTEGER NOT NULL,
  "attempts" INTEGER NOT NULL DEFAULT 0,
  "last_error" TEXT NULL,
  "parked" INTEGER NOT NULL DEFAULT 0 CHECK ("parked" IN (0, 1))
)''',
  '''
CREATE TABLE "sync_state" (
  "id" INTEGER NOT NULL,
  "pull_cursor" INTEGER NOT NULL DEFAULT 0,
  "device_id" TEXT NOT NULL,
  "last_synced_at" INTEGER NULL,
  "user_id" TEXT NULL,
  "region" TEXT NULL,
  "secure_storage_reset" INTEGER NOT NULL DEFAULT 0 CHECK ("secure_storage_reset" IN (0, 1)),
  PRIMARY KEY ("id")
)''',
];

// The links table of schema versions 4 and 5, which the version 6 migration
// extends.
const _relativeLinksV4V5 = '''
CREATE TABLE "relative_links" (
  "id" TEXT NOT NULL,
  "direction" TEXT NOT NULL,
  "profile_id" TEXT NOT NULL,
  "role" TEXT NOT NULL,
  "counterpart_name" TEXT NULL,
  "active" INTEGER NOT NULL DEFAULT 1 CHECK ("active" IN (0, 1)),
  "notify_missed" INTEGER NOT NULL DEFAULT 1 CHECK ("notify_missed" IN (0, 1)),
  "created_at" INTEGER NOT NULL,
  PRIMARY KEY ("id")
)''';

void main() {
  test('version 1 -> 2 keeps dose events and adds the reminder tables',
      () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          _unchangedSinceV1.forEach(raw.execute);
          raw
            ..execute(_v1DoseEvents)
            ..execute(_medicationsV1V2)
            ..execute(
              "INSERT INTO dose_events (id, profile_id, medication_id, "
              "event_type, at) VALUES ('e1', 'p', 'm', 'taken', 1)",
            )
            ..execute('PRAGMA user_version = 1');
        },
      ),
    );
    addTearDown(db.close);

    final events = await db.select(db.doseEvents).get();
    expect(events.single.id, 'e1');
    expect(events.single.snoozeUntil, isNull);

    await db.into(db.doseEvents).insert(
          const DoseEventRow(
            id: 'e2',
            profileId: 'p',
            medicationId: 'm',
            eventType: 'snoozed',
            at: 1,
            snoozeUntil: 2,
          ),
        );
    expect(
      (await db.select(db.doseEvents).get()).map((e) => e.snoozeUntil),
      [null, 2],
    );
    expect(await db.select(db.reminderDefaults).get(), isEmpty);
    expect(await db.select(db.medicationReminderSettings).get(), isEmpty);
    expect(await db.select(db.appliedNotifications).get(), isEmpty);
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.single, db.schemaVersion);
  });

  test('version 2 -> 3 keeps medications and adds the stock baseline',
      () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          _unchangedSinceV1.forEach(raw.execute);
          raw
            ..execute(_medicationsV1V2)
            ..execute(_doseEventsV2)
            ..execute(
              "INSERT INTO medications (id, profile_id, name, tz_mode, "
              "stock_count, privacy, client_updated_at, updated_by_device) "
              "VALUES ('m1', 'p', 'Med', 'local', '30', 'shared', 7, 'd')",
            )
            ..execute('PRAGMA user_version = 2');
        },
      ),
    );
    addTearDown(db.close);

    final row = (await db.select(db.medications).get()).single;
    expect(row.stockCount, '30');
    expect(row.stockSetAt, isNull);
    await (db.update(db.medications)..where((m) => m.id.equals('m1')))
        .write(const MedicationsCompanion(stockSetAt: Value(9)));
    expect((await db.select(db.medications).getSingle()).stockSetAt, 9);
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.single, db.schemaVersion);
  });

  test('version 3 -> 4 moves the cursor to every profile and backfills',
      () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          _unchangedSinceV1.forEach(raw.execute);
          raw
            ..execute(_medicationsV1V2.replaceFirst(
              '"low_stock_days" INTEGER NULL,',
              '"low_stock_days" INTEGER NULL, "stock_set_at" INTEGER NULL,',
            ))
            ..execute(_doseEventsV2)
            ..execute(
              "INSERT INTO sync_state (id, pull_cursor, device_id) "
              "VALUES (1, 41, 'dev')",
            )
            ..execute(
              "INSERT INTO profiles VALUES "
              "('self-1', 'self', 'Me', 'UTC', 1, 'd', NULL), "
              "('kid-1', 'managed', 'Kid', 'UTC', 1, 'd', NULL)",
            )
            ..execute(
              "INSERT INTO medications (id, profile_id, name, tz_mode, "
              "privacy, client_updated_at, updated_by_device) "
              "VALUES ('m1', 'kid-1', 'Med', 'local', 'shared', 7, 'd')",
            )
            ..execute(
              "INSERT INTO schedules VALUES "
              "('s1', 'm1', '{}', 7, 'd', NULL)",
            )
            ..execute(
              "INSERT INTO dose_events (id, profile_id, medication_id, "
              "event_type, at) VALUES ('e1', 'kid-1', 'm1', 'taken', 1)",
            )
            ..execute(
              "INSERT INTO outbox (entity_kind, op, entity_id, "
              "client_updated_at) VALUES "
              "('profile', 'upsert', 'kid-1', 1), "
              "('medication', 'upsert', 'm1', 1), "
              "('schedule', 'upsert', 's1', 1), "
              "('dose_event', 'upsert', 'e1', 1), "
              "('medication', 'upsert', 'gone', 1)",
            )
            ..execute('PRAGMA user_version = 3');
        },
      ),
    );
    addTearDown(db.close);

    final scopes = await db.select(db.accessScopes).get();
    expect(
      {for (final s in scopes) s.profileId: (s.role, s.kind, s.cursor)},
      {
        'self-1': ('owner', 'self', 41),
        'kid-1': ('owner', 'managed', 41),
      },
    );
    final devices = await db.select(db.profileDeviceSettings).get();
    expect(
      {for (final d in devices) d.profileId: d.remindOnDevice},
      {'kid-1': true},
    );
    final outbox = await db.select(db.outbox).get();
    expect(
      outbox.map((e) => e.profileId),
      ['kid-1', 'kid-1', 'kid-1', 'kid-1', ''],
      reason: 'an entry of an unknown entity keeps an empty profile id',
    );
    final medication = await db.select(db.medications).getSingle();
    expect((medication.name, medication.redacted), ('Med', false));
    await db.into(db.medications).insert(
          const MedicationRow(
            id: 'm2',
            profileId: 'kid-1',
            name: null,
            tzMode: 'local',
            privacy: 'anonymous',
            redacted: true,
            clientUpdatedAt: 0,
            updatedByDevice: '',
          ),
        );
    final profile = (await db.select(db.profiles).get()).first;
    expect(profile.missedAlertMinutes, 30);
    expect(profile.missedAlertsEnabled, isTrue);
    expect((await db.select(db.schedules).getSingle()).redacted, isFalse);
    expect(await db.select(db.relativeLinks).get(), isEmpty);
    expect(await db.select(db.pushState).get(), isEmpty);
    expect(await db.select(db.doseEvents).get(), hasLength(1));
  });

  test('version 4 -> 5 adds an empty sync lease', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) => raw
          ..execute(_unchangedSinceV1.last)
          ..execute(_relativeLinksV4V5)
          ..execute('PRAGMA user_version = 4'),
      ),
    );
    addTearDown(db.close);

    expect(await db.select(db.syncLeases).get(), isEmpty);
    await db.into(db.syncLeases).insert(
          SyncLeasesCompanion.insert(id: const Value(1)),
        );
    final lease = await db.select(db.syncLeases).getSingle();
    expect((lease.holder, lease.epoch, lease.expiresAt), (null, 0, 0));
    await expectLater(
      db.into(db.syncLeases).insert(
            SyncLeasesCompanion.insert(id: const Value(2)),
          ),
      throwsA(anything),
      reason: 'a second row would be a second lease',
    );
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.single, db.schemaVersion);
  });

  test('version 5 -> 6 keeps links and adds names and the banner baseline',
      () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) => raw
          ..execute(_unchangedSinceV1.last)
          ..execute(_relativeLinksV4V5)
          ..execute(
            "INSERT INTO relative_links (id, direction, profile_id, role, "
            "created_at) VALUES ('g1', 'outgoing', 'p1', 'viewer', 5)",
          )
          ..execute('PRAGMA user_version = 5'),
      ),
    );
    addTearDown(db.close);

    final link = await db.select(db.relativeLinks).getSingle();
    expect(link.id, 'g1');
    expect((link.profileName, link.profileKind), ('', 'self'));
    // No baseline yet: the first refresh of the links sets it.
    expect(await db.select(db.syncState).get(), isEmpty);
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.single, db.schemaVersion);
  });
}
