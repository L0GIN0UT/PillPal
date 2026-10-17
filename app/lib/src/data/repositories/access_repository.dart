import 'package:drift/drift.dart';

import '../db/database.dart';

/// The scopes (profiles) the signed-in account can access and what each
/// means locally: its role, archive state, the pull cursor, and whether this
/// device reminds for it. Written by the scoped pull
/// (`ScopedPuller`) and by local profile creation; read by the data layer
/// and, from 3.8, by the Family screens.
class AccessRepository {
  /// Creates the repository.
  AccessRepository(this._db);

  final AppDatabase _db;

  /// All scopes, owners first, then by profile id.
  Future<List<AccessScopeRow>> scopes() => _scopesQuery().get();

  /// Updates for all scopes.
  Stream<List<AccessScopeRow>> watchScopes() => _scopesQuery().watch();

  Selectable<AccessScopeRow> _scopesQuery() {
    return _db.select(_db.accessScopes)
      ..orderBy([
        (row) => OrderingTerm.desc(row.role.equals(ScopeRole.owner)),
        (row) => OrderingTerm.asc(row.profileId),
      ]);
  }

  /// The scope of [profileId], or null when it is not (or no longer) one.
  Future<AccessScopeRow?> scope(String profileId) {
    return (_db.select(_db.accessScopes)
          ..where((row) => row.profileId.equals(profileId)))
        .getSingleOrNull();
  }

  /// The pull cursor of [profileId]; 0 for an unknown scope.
  Future<int> cursorOf(String profileId) async =>
      (await scope(profileId))?.cursor ?? 0;

  /// The account's own `self` profile: kind `self` in a scope where the
  /// account is the owner. Other people's `self` profiles, which relatives
  /// hold locally too, never qualify.
  Future<ProfileRow?> ownSelfProfile() => _ownSelfQuery().getSingleOrNull();

  /// Updates of [ownSelfProfile]. The query joins `access_scopes`, which a
  /// pull writes on every page (cursor): only a changed profile is emitted,
  /// or every screen watching it would reload during a sync.
  Stream<ProfileRow?> watchOwnSelfProfile() =>
      _ownSelfQuery().watchSingleOrNull().distinct();

  Selectable<ProfileRow> _ownSelfQuery() {
    final query = _db.select(_db.profiles).join([
      innerJoin(
        _db.accessScopes,
        _db.accessScopes.profileId.equalsExp(_db.profiles.id),
      ),
    ])
      ..where(
        _db.accessScopes.role.equals(ScopeRole.owner) &
            _db.profiles.kind.equals('self') &
            _db.profiles.deletedAt.isNull(),
      );
    return query.map((row) => row.readTable(_db.profiles));
  }

  /// Whether this device fires reminders for [profileId]: its explicit
  /// switch, else the default of the role ([ScopeRole.remindsByDefault]).
  Future<bool> remindsOnDevice(String profileId) async {
    final row = await (_db.select(_db.profileDeviceSettings)
          ..where((r) => r.profileId.equals(profileId)))
        .getSingleOrNull();
    final role = (await scope(profileId))?.role;
    if (role == null) {
      return false;
    }
    return ScopeRole.remindsByDefault(role, row?.remindOnDevice);
  }

  /// Turns reminders of [profileId] on this device on or off.
  Future<void> setRemindOnDevice(String profileId, {required bool enabled}) {
    return _db.into(_db.profileDeviceSettings).insertOnConflictUpdate(
          ProfileDeviceSettingsCompanion.insert(
            profileId: profileId,
            remindOnDevice: enabled,
          ),
        );
  }
}
