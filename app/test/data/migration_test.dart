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

void main() {
  test('version 1 -> 2 keeps dose events and adds the reminder tables',
      () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
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
          raw
            ..execute(_medicationsV1V2)
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
    expect(version.data.values.single, 3);
  });
}
