import 'package:drift/drift.dart';

// Local mirror of the server entities (TZ §4.1). Instants are stored as
// integer microseconds since the epoch (UTC): the server's conflict keys have
// microsecond precision and must round-trip exactly. Rules and payloads are
// JSON text. No foreign keys: a pulled child may reference a parent that a
// later page (or another device) settles, and the server enforces integrity.

/// Profiles (`self` from registration, `managed` created by the user).
@DataClassName('ProfileRow')
@TableIndex(name: 'profiles_live', columns: {#deletedAt})
class Profiles extends Table {
  /// Client-generated UUID.
  TextColumn get id => text()();

  /// `self` or `managed`.
  TextColumn get kind => text()();

  /// Display name.
  TextColumn get displayName => text()();

  /// IANA time zone.
  TextColumn get timezone => text()();

  /// Last-write-wins key, microseconds since epoch (UTC).
  IntColumn get clientUpdatedAt => integer()();

  /// Device that wrote [clientUpdatedAt] (tie-break); empty for rows of
  /// other people's profiles (their envelope hides it).
  TextColumn get updatedByDevice => text()();

  /// Tombstone instant (microseconds), null while live.
  IntColumn get deletedAt => integer().nullable()();

  /// Minutes after a due dose before relatives are alerted (5..720, server
  /// default 30; schema version 4). Only owners and guardians receive it.
  IntColumn get missedAlertMinutes =>
      integer().withDefault(const Constant(30))();

  /// Whether relatives are alerted about missed doses (schema version 4).
  BoolColumn get missedAlertsEnabled =>
      boolean().withDefault(const Constant(true))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Medications of a profile.
@DataClassName('MedicationRow')
@TableIndex(name: 'medications_profile', columns: {#profileId})
class Medications extends Table {
  /// Client-generated UUID.
  TextColumn get id => text()();

  /// Owning profile (immutable).
  TextColumn get profileId => text()();

  /// Free-text name; null for a redacted (`anonymous`) medication of
  /// someone else's profile, which never shows it (schema version 4).
  TextColumn get name => text().nullable()();

  /// Dosage form, free text.
  TextColumn get form => text().nullable()();

  /// Strength, free text (e.g. "500 mg").
  TextColumn get strengthText => text().nullable()();

  /// Notes (e.g. "after meals").
  TextColumn get notes => text().nullable()();

  /// `local` or `fixed`.
  TextColumn get tzMode => text()();

  /// IANA zone when [tzMode] is `fixed`.
  TextColumn get fixedTz => text().nullable()();

  /// Decimal stock as the server's string form (e.g. "12.500").
  TextColumn get stockCount => text().nullable()();

  /// Stock unit.
  TextColumn get stockUnit => text().nullable()();

  /// Low-stock warning threshold in days.
  IntColumn get lowStockDays => integer().nullable()();

  /// When [stockCount] was entered (microseconds, UTC): the stock baseline
  /// doses are subtracted from (docs/adr/0004-stock-tracking.md, schema
  /// version 3). Null for rows written before it existed.
  IntColumn get stockSetAt => integer().nullable()();

  /// `shared`, `anonymous` or `hidden`.
  TextColumn get privacy => text()();

  /// Whether the server projected this row for a relative (`anonymous`
  /// medication: no name, notes or stock; ADR 0006 §3). Schema version 4.
  BoolColumn get redacted => boolean().withDefault(const Constant(false))();

  /// Last-write-wins key, microseconds since epoch (UTC); 0 for redacted
  /// rows (their envelope carries none).
  IntColumn get clientUpdatedAt => integer()();

  /// Device that wrote [clientUpdatedAt] (tie-break); empty for rows of
  /// other people's profiles.
  TextColumn get updatedByDevice => text()();

  /// Tombstone instant (microseconds), null while live.
  IntColumn get deletedAt => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Schedules of a medication.
@DataClassName('ScheduleRow')
@TableIndex(name: 'schedules_medication', columns: {#medicationId})
class Schedules extends Table {
  /// Client-generated lowercase UUID (part of occurrence keys).
  TextColumn get id => text()();

  /// Owning medication (immutable).
  TextColumn get medicationId => text()();

  /// Canonical rule v1 JSON (docs/spec/schedule.md). A redacted rule has
  /// no `dose` in its time slots.
  TextColumn get rule => text()();

  /// Whether the server projected this schedule for a relative: the rule
  /// has no doses (schema version 4; `parseScheduleRow`).
  BoolColumn get redacted => boolean().withDefault(const Constant(false))();

  /// Last-write-wins key, microseconds since epoch (UTC).
  IntColumn get clientUpdatedAt => integer()();

  /// Device that wrote [clientUpdatedAt] (tie-break).
  TextColumn get updatedByDevice => text()();

  /// Tombstone instant (microseconds), null while live.
  IntColumn get deletedAt => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Append-only dose events (TZ §2.4).
@DataClassName('DoseEventRow')
@TableIndex(name: 'dose_events_medication_at', columns: {#medicationId, #at})
@TableIndex(name: 'dose_events_occurrence', columns: {#occurrenceKey})
class DoseEvents extends Table {
  /// Client-generated UUID (idempotency key).
  TextColumn get id => text()();

  /// Profile of the medication.
  TextColumn get profileId => text()();

  /// Medication.
  TextColumn get medicationId => text()();

  /// `taken`, `skipped`, `snoozed` or `undo`.
  TextColumn get eventType => text()();

  /// When it happened, microseconds since epoch (UTC).
  IntColumn get at => integer()();

  /// Occurrence key `{schedule_id}/{YYYY-MM-DD}T{HH:MM}`, if scheduled.
  TextColumn get occurrenceKey => text().nullable()();

  /// Event corrected by an `undo`.
  TextColumn get targetEventId => text().nullable()();

  /// Optional note.
  TextColumn get note => text().nullable()();

  /// Server receipt time (microseconds); null until pulled.
  IntColumn get recordedAt => integer().nullable()();

  /// Recording device as stored by the server; null until pulled.
  TextColumn get deviceId => text().nullable()();

  /// When a `snoozed` dose is due again (microseconds, UTC); null for every
  /// other type (ADR 0001 §7, schema version 2).
  IntColumn get snoozeUntil => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Local mutations not yet accepted by the server, pushed in [seq] order.
@DataClassName('OutboxEntry')
@TableIndex(name: 'outbox_entity', columns: {#entityKind, #entityId})
class Outbox extends Table {
  /// Push order.
  IntColumn get seq => integer().autoIncrement()();

  /// Wire entity name (`profile`, `medication`, `schedule`, `dose_event`).
  TextColumn get entityKind => text()();

  /// `upsert` or `delete`.
  TextColumn get op => text()();

  /// Entity id.
  TextColumn get entityId => text()();

  /// Full `*Data` JSON for upserts; null for deletes.
  TextColumn get payload => text().nullable()();

  /// Conflict key of this write, microseconds since epoch (UTC).
  IntColumn get clientUpdatedAt => integer()();

  /// Profile (sync scope) the entity belongs to; empty when unknown (rows
  /// queued before schema version 4 whose entity is gone). Eviction of a
  /// scope drops its entries.
  TextColumn get profileId => text().withDefault(const Constant(''))();

  /// Failed push attempts.
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  /// Last rejection code, if any.
  TextColumn get lastError => text().nullable()();

  /// Permanently rejected: kept for inspection, never pushed again.
  BoolColumn get parked => boolean().withDefault(const Constant(false))();
}

/// Single-row sync bookkeeping (row id 1), created with the database, so the
/// device id is per installation (the database is excluded from backups).
@DataClassName('SyncStateRow')
class SyncState extends Table {
  /// Always 1.
  IntColumn get id => integer()();

  /// Legacy global pull cursor (schema versions 1..3). Since version 4 each
  /// scope has its own cursor in `access_scopes`; the migration copies this
  /// one into all of them and nothing reads it afterwards.
  IntColumn get pullCursor => integer().withDefault(const Constant(0))();

  /// Stable device id (`X-Device-ID`, conflict-key tie-break).
  TextColumn get deviceId => text()();

  /// Last successful sync, microseconds since epoch (UTC).
  IntColumn get lastSyncedAt => integer().nullable()();

  /// Account the local data belongs to (JWT `sub`); null before sign-in.
  TextColumn get userId => text().nullable()();

  /// Data region of that account.
  TextColumn get region => text().nullable()();

  /// Whether the keystore was cleared for this installation (the iOS
  /// Keychain outlives an uninstall).
  BoolColumn get secureStorageReset =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// The sync lease (row id 1): one holder at a time for everything that
/// writes the outbox results or the session tokens, across isolates and
/// engines (docs/adr/0001-local-notifications.md, addendum 3.7). `epoch`
/// grows with every acquisition and fences stale holders; `expires_at`
/// (microseconds since epoch, UTC) frees a lease whose holder died.
@DataClassName('SyncLeaseRow')
class SyncLeases extends Table {
  /// Always 1 (a second row would be a second lease).
  IntColumn get id => integer().check(id.equals(1))();

  /// Random id of the current holder; null when free.
  TextColumn get holder => text().nullable()();

  /// Number of acquisitions so far.
  IntColumn get epoch => integer().withDefault(const Constant(0))();

  /// When the lease lapses unless renewed.
  IntColumn get expiresAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
