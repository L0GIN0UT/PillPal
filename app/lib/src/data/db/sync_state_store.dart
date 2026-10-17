import 'package:drift/drift.dart';

import '../clock.dart';
import 'database.dart';

/// Reads and writes the single [SyncState] row (device id, account binding,
/// last sync; pull cursors live per scope in `access_scopes`).
class SyncStateStore {
  /// Creates a store over [db]; [newId] generates the device id once.
  SyncStateStore(this._db, this._newId);

  static const int _rowId = 1;

  final AppDatabase _db;
  final IdGenerator _newId;

  /// The state row (created with a new device id on first use).
  Future<SyncStateRow> row() => _row();

  Future<SyncStateRow> _row() async {
    return _db.transaction(() async {
      final existing = await (_db.select(_db.syncState)
            ..where((row) => row.id.equals(_rowId)))
          .getSingleOrNull();
      if (existing != null) {
        return existing;
      }
      final row = SyncStateRow(
        id: _rowId,
        pullCursor: 0,
        deviceId: _newId(),
        secureStorageReset: false,
      );
      await _db.into(_db.syncState).insert(row);
      return row;
    });
  }

  /// The stable id of this installation (created on first use).
  Future<String> deviceId() async => (await _row()).deviceId;

  /// When the last sync completed, if ever.
  Future<DateTime?> lastSyncedAt() async {
    final micros = (await _row()).lastSyncedAt;
    return micros == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
  }

  /// The account the local data belongs to, or null.
  Future<String?> boundUserId() async => (await _row()).userId;

  /// Binds the local data to [userId] in [region].
  Future<void> bindAccount(String userId, String region) async {
    await _row();
    await (_db.update(_db.syncState)..where((row) => row.id.equals(_rowId)))
        .write(
            SyncStateCompanion(userId: Value(userId), region: Value(region)));
  }

  /// True exactly once per installation: the keystore must be cleared.
  Future<bool> claimSecureStorageReset() {
    return _db.transaction(() async {
      final row = await _row();
      if (row.secureStorageReset) {
        return false;
      }
      await (_db.update(_db.syncState)..where((r) => r.id.equals(_rowId)))
          .write(const SyncStateCompanion(secureStorageReset: Value(true)));
      return true;
    });
  }

  /// The "new relative" baseline (`SyncState.relativesSeenAt`), if set.
  Future<DateTime?> relativesSeenAt() async {
    final micros = (await _row()).relativesSeenAt;
    return micros == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
  }

  /// Updates of [relativesSeenAt].
  Stream<DateTime?> watchRelativesSeenAt() {
    return (_db.select(_db.syncState)..where((row) => row.id.equals(_rowId)))
        .watchSingleOrNull()
        .map((row) => row?.relativesSeenAt)
        .distinct()
        .map(
          (micros) => micros == null
              ? null
              : DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true),
        );
  }

  /// Moves the "new relative" baseline to [at], never backwards.
  Future<void> advanceRelativesSeenAt(DateTime at) async {
    final current = (await _row()).relativesSeenAt;
    final micros = at.toUtc().microsecondsSinceEpoch;
    if (current != null && current >= micros) {
      return;
    }
    await (_db.update(_db.syncState)..where((row) => row.id.equals(_rowId)))
        .write(SyncStateCompanion(relativesSeenAt: Value(micros)));
  }

  /// Records a completed sync at [at].
  Future<void> markSynced(DateTime at) async {
    await _row();
    await (_db.update(_db.syncState)..where((row) => row.id.equals(_rowId)))
        .write(
      SyncStateCompanion(
          lastSyncedAt: Value(at.toUtc().microsecondsSinceEpoch)),
    );
  }
}
