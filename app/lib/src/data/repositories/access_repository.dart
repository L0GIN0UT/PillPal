import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show listEquals;

import '../db/database.dart';
import 'profile_access.dart';

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

  /// What the account may do on [profileId]; null for an unknown scope or a
  /// deleted profile. A null [profileId] means the account's own `self`
  /// profile. Only changes that matter for access are emitted: a pull
  /// writes the scope's cursor on every page.
  Stream<ProfileAccess?> watchAccess(String? profileId) {
    final Expression<bool> which = profileId == null
        ? _db.accessScopes.role.equals(ScopeRole.owner) &
            _db.profiles.kind.equals('self')
        : _db.profiles.id.equals(profileId);
    return _accessSelect(which).watchSingleOrNull().distinct();
  }

  /// Every profile the account can see, its own `self` first, then the
  /// profiles it runs (owner or guardian), then the others by name.
  Stream<List<ProfileAccess>> watchAccessible() {
    return _accessSelect()
        .watch()
        .map(sortAccessible)
        .distinct((a, b) => listEquals(a, b));
  }

  Selectable<ProfileAccess> _accessSelect([Expression<bool>? which]) {
    final query = _db.select(_db.profiles).join([
      innerJoin(
        _db.accessScopes,
        _db.accessScopes.profileId.equalsExp(_db.profiles.id),
      ),
    ]);
    final live = _db.profiles.deletedAt.isNull();
    query.where(which == null ? live : live & which);
    return query.map(
      (row) => ProfileAccess.of(
        row.readTable(_db.profiles),
        row.readTable(_db.accessScopes),
      ),
    );
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

/// Orders [profiles] for pickers: the account's own `self` profile, then the
/// ones it runs, then the others, each group by name.
List<ProfileAccess> sortAccessible(List<ProfileAccess> profiles) {
  int group(ProfileAccess access) {
    if (access.isOwnSelf) {
      return 0;
    }
    return access.hasFullAccess ? 1 : 2;
  }

  return [...profiles]..sort((a, b) {
      final byGroup = group(a).compareTo(group(b));
      if (byGroup != 0) {
        return byGroup;
      }
      final byName = a.profile.displayName
          .toLowerCase()
          .compareTo(b.profile.displayName.toLowerCase());
      return byName != 0 ? byName : a.id.compareTo(b.id);
    });
}
