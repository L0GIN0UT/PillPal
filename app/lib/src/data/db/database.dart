import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'access_tables.dart';
import 'reminder_tables.dart';
import 'tables.dart';

export 'access_tables.dart';
export 'reminder_tables.dart';
export 'scope_roles.dart';
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
    AccessScopes,
    RelativeLinks,
    ProfileDeviceSettings,
    PushState,
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
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (migrator) => migrator.createAll(),
        onUpgrade: _upgrade,
        beforeOpen: (details) => customStatement(
          'PRAGMA busy_timeout = ${busyTimeout.inMilliseconds}',
        ),
      );

  /// Erases all account data in one transaction: entities, outbox, the
  /// scopes with their cursors (server sequence numbers are global, not per
  /// account), relatives, per-profile device settings, push registration and
  /// the account binding. The device id and the device-wide reminder
  /// defaults stay. Applied notifications are forgotten too (they reference
  /// the account's medications); the caller cancels the OS notifications
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
      await delete(accessScopes).go();
      await delete(relativeLinks).go();
      await delete(profileDeviceSettings).go();
      await delete(pushState).go();
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

  /// Removes everything a scope (profile) holds locally: its rows, their
  /// outbox entries, reminder settings and device setting, and the scope
  /// itself. Used when access ends, narrows (role change) or goes stale.
  /// Applied notifications stay: the next re-plan finds their schedules
  /// gone and cancels them in the OS.
  Future<void> evictScope(String profileId) {
    const medicationIds = '(SELECT id FROM medications WHERE profile_id = ?)';
    return transaction(() async {
      await _removeWhere(
        doseEvents,
        'profile_id = ? OR medication_id IN $medicationIds',
        profileId,
        2,
      );
      await _removeWhere(
        schedules,
        'medication_id IN $medicationIds',
        profileId,
        1,
      );
      await _removeWhere(
        medicationReminderSettings,
        'medication_id IN $medicationIds',
        profileId,
        1,
      );
      await _removeWhere(medications, 'profile_id = ?', profileId, 1);
      await _removeWhere(outbox, 'profile_id = ?', profileId, 1);
      await _removeWhere(profiles, 'id = ?', profileId, 1);
      await _removeWhere(profileDeviceSettings, 'profile_id = ?', profileId, 1);
      await _removeWhere(accessScopes, 'profile_id = ?', profileId, 1);
    });
  }

  /// Deletes the rows of [table] matching [where], whose [placeholders] `?`
  /// all stand for [profileId]; notifies the table's streams.
  Future<void> _removeWhere(
    TableInfo<Table, Object?> table,
    String where,
    String profileId,
    int placeholders,
  ) async {
    await customUpdate(
      'DELETE FROM ${table.actualTableName} WHERE $where',
      variables: List.filled(placeholders, Variable.withString(profileId)),
      updates: {table},
      updateKind: UpdateKind.delete,
    );
  }

  /// Prepares a full resync (`410 cursor_expired`): drops synced state that a
  /// pull from cursor 0 restores, keeping entities with pending changes and
  /// dose events the server has not acknowledged yet, and rewinds every
  /// scope's cursor.
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
      await update(accessScopes).write(
        const AccessScopesCompanion(
          cursor: Value(0),
          backfillUntil: Value(null),
        ),
      );
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
    if (from < 4) {
      await _upgradeToScopes(migrator);
    }
  }

  /// Version 4 (milestone 3.6, docs/adr/0006-sync-scopes-and-privacy-projection.md
  /// §8): the pull cursor moves from one global value to one per profile
  /// (all local profiles were owned, and `seq` is global, so the old value
  /// is valid for every scope); managed profiles keep reminding on this
  /// device; rows learn which profile an outbox entry belongs to; redacted
  /// medications and schedules and the profile alert settings get columns.
  Future<void> _upgradeToScopes(Migrator migrator) async {
    await migrator.addColumn(profiles, profiles.missedAlertMinutes);
    await migrator.addColumn(profiles, profiles.missedAlertsEnabled);
    await migrator.addColumn(schedules, schedules.redacted);
    // `name` becomes nullable: SQLite cannot relax a NOT NULL in place.
    await migrator.alterTable(
      TableMigration(medications, newColumns: [medications.redacted]),
    );
    await migrator.addColumn(outbox, outbox.profileId);
    await migrator.createTable(accessScopes);
    await migrator.createTable(relativeLinks);
    await migrator.createTable(profileDeviceSettings);
    await migrator.createTable(pushState);
    for (final statement in _scopeBackfill) {
      await customStatement(statement);
    }
  }

  static const List<String> _scopeBackfill = [
    'UPDATE outbox SET profile_id = entity_id '
        "WHERE entity_kind = 'profile'",
    'UPDATE outbox SET profile_id = COALESCE((SELECT m.profile_id '
        "FROM medications m WHERE m.id = outbox.entity_id), '') "
        "WHERE entity_kind = 'medication'",
    'UPDATE outbox SET profile_id = COALESCE((SELECT m.profile_id '
        'FROM schedules s JOIN medications m ON m.id = s.medication_id '
        "WHERE s.id = outbox.entity_id), '') "
        "WHERE entity_kind = 'schedule'",
    'UPDATE outbox SET profile_id = COALESCE((SELECT d.profile_id '
        "FROM dose_events d WHERE d.id = outbox.entity_id), '') "
        "WHERE entity_kind = 'dose_event'",
    'INSERT INTO access_scopes (profile_id, role, kind, archived, cursor) '
        "SELECT id, 'owner', kind, 0, "
        'COALESCE((SELECT pull_cursor FROM sync_state WHERE id = 1), 0) '
        'FROM profiles',
    'INSERT INTO profile_device_settings (profile_id, remind_on_device) '
        "SELECT id, 1 FROM profiles WHERE kind = 'managed'",
  ];
}
