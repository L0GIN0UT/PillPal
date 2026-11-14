import 'package:drift/drift.dart';

// Local state of sync scopes and relatives (milestone 3.6, schema version 4,
// docs/adr/0006-sync-scopes-and-privacy-projection.md). A scope is a profile:
// the server journals every change per profile and the client keeps one
// pull cursor per scope. A profile row exists locally only while its scope
// is listed in `access_scopes` (eviction removes both).

/// The scopes (profiles) this account can access, with the caller's role.
@DataClassName('AccessScopeRow')
class AccessScopes extends Table {
  /// Profile id (the scope).
  TextColumn get profileId => text()();

  /// `owner`, `guardian`, `editor` or `viewer` (`ScopeRole`).
  TextColumn get role => text()();

  /// `self` or `managed`.
  TextColumn get kind => text()();

  /// A read-only archive of a managed profile (ADR 0005 §5): no reminders,
  /// no writes.
  BoolColumn get archived => boolean().withDefault(const Constant(false))();

  /// When an archive is purged (microseconds, UTC), once its owner is gone.
  IntColumn get archivePurgeAfter => integer().nullable()();

  /// When the owner's devices last synced, floored to the hour by the
  /// server (microseconds, UTC); only for other people's `self` profiles.
  IntColumn get ownerLastSeenAt => integer().nullable()();

  /// Last journal position of this scope applied locally.
  IntColumn get cursor => integer().withDefault(const Constant(0))();

  /// The server's `backfill_until` of an unfinished backfill, echoed in the
  /// next pull request until [cursor] reaches it; null otherwise.
  IntColumn get backfillUntil => integer().nullable()();

  /// Last successful pull that listed this scope (microseconds, UTC); null
  /// until the first one. A scope of another person that stays unpulled for
  /// the account-deletion grace period is evicted.
  IntColumn get lastPulledAt => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {profileId};
}

/// Links between accounts as listed by `GET /v1/grants` (outgoing: who sees
/// my profiles; incoming: whose profiles I see). The Family tab keeps the
/// last answer here (`RelativesRepository`), so it shows the links offline
/// too. Wiped with the account's data.
@DataClassName('RelativeLinkRow')
class RelativeLinks extends Table {
  /// Grant id (server-generated).
  TextColumn get id => text()();

  /// `outgoing` or `incoming`.
  TextColumn get direction => text()();

  /// The profile the grant is on.
  TextColumn get profileId => text()();

  /// `viewer`, `editor` or `guardian`.
  TextColumn get role => text()();

  /// The other person's display name, when the server tells it.
  TextColumn get counterpartName => text().nullable()();

  /// Whether the grant gives access now (an outgoing grant of an account in
  /// its deletion grace period is inactive).
  BoolColumn get active => boolean().withDefault(const Constant(true))();

  /// Whether the grantee is alerted about missed doses.
  BoolColumn get notifyMissed => boolean().withDefault(const Constant(true))();

  /// When the grant was made (microseconds, UTC).
  IntColumn get createdAt => integer()();

  /// The profile's name as the server tells it (schema version 6).
  TextColumn get profileName => text().withDefault(const Constant(''))();

  /// `self` or `managed` (schema version 6).
  TextColumn get profileKind => text().withDefault(const Constant('self'))();

  /// The profile that stands for the other person (schema version 10,
  /// docs/adr/0020 §4): the grantee's self profile on an outgoing link (null
  /// when the server does not tell it), the profile itself on an incoming
  /// one. The key of the account's private note and of the relative's row.
  TextColumn get counterpartProfileId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// The account's private notes about its relatives, as listed by
/// `GET /v1/grants` (docs/adr/0020 §4; schema version 10). Only their author
/// ever sees them; online-edit only, so this is a cache the Family tab reads
/// offline, replaced with every refresh of the links and wiped with the
/// account's data. A note may carry health context: never logged.
@DataClassName('RelativeNoteRow')
class RelativeNotes extends Table {
  /// The subject: a relative's self profile or a managed profile.
  TextColumn get profileId => text()();

  /// The note, 1-20 visible characters.
  TextColumn get note => text()();

  /// When the server last changed it (microseconds, UTC).
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {profileId};
}

/// Per-device settings of a profile; never synced.
@DataClassName('ProfileDeviceSettingRow')
class ProfileDeviceSettings extends Table {
  /// Profile id.
  TextColumn get profileId => text()();

  /// Whether this device fires the profile's reminders. Managed profiles
  /// remind only while this is on; the own `self` profile always reminds.
  BoolColumn get remindOnDevice => boolean()();

  @override
  Set<Column<Object>> get primaryKey => {profileId};
}

/// Push registration bookkeeping (a single row with [id] 1, written by the
/// push client of milestone 3.9).
@DataClassName('PushStateRow')
class PushState extends Table {
  /// Always 1.
  IntColumn get id => integer()();

  /// `fcm`, `apns` or `rustore` while a token is registered, else null.
  TextColumn get provider => text().nullable()();

  /// When the token was last registered (microseconds, UTC).
  IntColumn get registeredAt => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
