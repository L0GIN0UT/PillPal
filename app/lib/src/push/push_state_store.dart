import 'package:drift/drift.dart';

import '../data/db/database.dart';
import 'push_provider_client.dart';

/// What this installation has registered with the backend (the single
/// `push_state` row): the provider whose token the server holds, so a need
/// that ends later knows there is something to delete. The token itself is
/// never stored here. Wiped with the account's data.
class PushStateStore {
  /// Creates the store over [_db].
  PushStateStore(this._db);

  static const int _rowId = 1;

  final AppDatabase _db;

  /// The provider whose token the server holds, or null.
  Future<PushProviderKind?> provider() async {
    final row = await (_db.select(_db.pushState)
          ..where((row) => row.id.equals(_rowId)))
        .getSingleOrNull();
    return PushProviderKind.fromWire(row?.provider);
  }

  /// Notes that [kind]'s token was registered at [at].
  Future<void> record(PushProviderKind kind, DateTime at) {
    return _db.into(_db.pushState).insertOnConflictUpdate(
          PushStateCompanion(
            id: const Value(_rowId),
            provider: Value(kind.wire),
            registeredAt: Value(at.toUtc().microsecondsSinceEpoch),
          ),
        );
  }

  /// Notes that the server holds no token of this installation.
  Future<void> clear() => _db.delete(_db.pushState).go();
}
