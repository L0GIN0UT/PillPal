import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'reminder_tables.dart';
import 'tables.dart';

export 'reminder_tables.dart';
export 'tables.dart';

part 'database.g.dart';

/// The app's local database (offline-first: the UI reads only from here).
@DriftDatabase(
  tables: [
    Profiles,
    Medications,
    Schedules,
    DoseEvents,
    Outbox,
    SyncState,
    ReminderDefaults,
    MedicationReminderSettings,
    AppliedNotifications,
  ],
)
class AppDatabase extends _$AppDatabase {
  /// Opens a database on [executor] (`NativeDatabase.memory()` in tests).
  AppDatabase(super.executor);

  /// Opens the on-device database file.
  ///
  /// Isolates of one engine share a single connection (notification actions
  /// write from a background isolate, docs/adr/0001-local-notifications.md
  /// §7); connections of separate engines wait for each other's locks.
  factory AppDatabase.open() => AppDatabase(
        driftDatabase(
          name: 'pillpal',
          native: const DriftNativeOptions(shareAcrossIsolates: true),
        ),
      );

  /// How long a connection waits for another one's write lock.
  static const Duration busyTimeout = Duration(seconds: 5);

  /// Bump on every schema change and add a step to [_upgrade].
  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (migrator) => migrator.createAll(),
        onUpgrade: _upgrade,
        beforeOpen: (details) => customStatement(
          'PRAGMA busy_timeout = ${busyTimeout.inMilliseconds}',
        ),
      );

  /// Erases all account data in one transaction: entities, outbox, the pull
  /// cursor (server sequence numbers are global, not per account) and the
  /// account binding. The device id and the device-wide reminder defaults
  /// stay. Applied notifications are forgotten too (they reference the
  /// account's medications); the caller cancels the OS notifications
  /// themselves (`ReminderSessionListener`, ADR 0002 §1).
  Future<void> wipeAccountData() {
    return transaction(() async {
      await delete(appliedNotifications).go();
      await delete(medicationReminderSettings).go();
      await delete(doseEvents).go();
      await delete(schedules).go();
      await delete(medications).go();
      await delete(profiles).go();
      await delete(outbox).go();
      await update(syncState).write(
        const SyncStateCompanion(
          pullCursor: Value(0),
          lastSyncedAt: Value(null),
          userId: Value(null),
          region: Value(null),
        ),
      );
    });
  }

  /// Prepares a full resync (`410 cursor_expired`): drops synced state that a
  /// pull from cursor 0 restores, keeping entities with pending changes and
  /// dose events the server has not acknowledged yet.
  Future<void> resetForFullResync() {
    return transaction(() async {
      for (final table in const ['profiles', 'medications', 'schedules']) {
        await customStatement(
          'DELETE FROM $table WHERE id NOT IN '
          '(SELECT entity_id FROM outbox WHERE parked = 0)',
        );
      }
      await customStatement(
        'DELETE FROM dose_events WHERE recorded_at IS NOT NULL AND id NOT IN '
        '(SELECT entity_id FROM outbox WHERE parked = 0)',
      );
      await update(syncState)
          .write(const SyncStateCompanion(pullCursor: Value(0)));
    });
  }

  /// Schema upgrade hook: one `if (from < N)` block per version, in order.
  Future<void> _upgrade(Migrator migrator, int from, int to) async {
    if (from > to) {
      throw StateError('Cannot downgrade the database from $from to $to');
    }
    if (from < 2) {
      // Reminders (milestone 2.3): snooze instants and local reminder state.
      await migrator.addColumn(doseEvents, doseEvents.snoozeUntil);
      await migrator.createTable(reminderDefaults);
      await migrator.createTable(medicationReminderSettings);
      await migrator.createTable(appliedNotifications);
    }
    if (from < 3) {
      // Stock baseline (milestone 2.4, docs/adr/0004-stock-tracking.md).
      await migrator.addColumn(medications, medications.stockSetAt);
    }
  }
}
