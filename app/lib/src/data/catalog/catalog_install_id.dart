import 'package:drift/drift.dart';

import '../clock.dart';
import '../config.dart';
import '../db/database.dart';
import '../db/sync_state_store.dart';

/// The random id sent as `X-Catalog-Install` to the catalog service
/// (ADR 0015 §3). It lets the catalog rate-limit an installation without
/// knowing who it is: it is never sent to the backend, the backend's device
/// id is never sent to the catalog, and it is not a credential.
///
/// It lives in the `sync_state` row, so `AppDatabase.wipeAccountData`
/// (sign-out, account deletion) clears it and the next account starts with
/// a new one; besides, it is replaced every 30 days.
class CatalogInstallId {
  /// Creates the source; [newId] generates the id, [clock] ages it.
  CatalogInstallId({
    required AppDatabase db,
    required SyncStateStore syncState,
    required IdGenerator newId,
    required Clock clock,
    Duration lifetime = CatalogPolicy.installIdLifetime,
  })  : _db = db,
        _syncState = syncState,
        _newId = newId,
        _clock = clock,
        _lifetime = lifetime;

  final AppDatabase _db;
  final SyncStateStore _syncState;
  final IdGenerator _newId;
  final Clock _clock;
  final Duration _lifetime;

  /// The current id; a new one is made when there is none or it is older
  /// than the lifetime.
  Future<String> current() {
    return _db.transaction(() async {
      final row = await _syncState.row();
      final now = _clock().toUtc().microsecondsSinceEpoch;
      final id = row.catalogInstallId;
      final createdAt = row.catalogInstallAt;
      if (id != null && createdAt != null) {
        final age = now - createdAt;
        if (age >= 0 && age < _lifetime.inMicroseconds) {
          return id;
        }
      }
      return _replace(now);
    });
  }

  Future<String> _replace(int now) async {
    final fresh = _newId();
    final statement = _db.update(_db.syncState)
      ..where((row) => row.id.equals(1));
    await statement.write(
      SyncStateCompanion(
        catalogInstallId: Value(fresh),
        catalogInstallAt: Value(now),
      ),
    );
    return fresh;
  }
}
