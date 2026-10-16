import '../db/database.dart';
import '../db/sync_state_store.dart';
import 'access_claims.dart';

/// Keeps the local database bound to one account.
///
/// Local data belongs to the account in `sync_state.user_id`. Signing in as
/// another account (or region), and every sign-out, erases it in one
/// transaction together with the outbox and the pull cursor, so one
/// account's changes are never pushed with another account's tokens.
/// Data written before the first sign-in (no bound account) is adopted by
/// the account that signs in.
class AccountBinding implements SessionListener {
  /// Creates the binding.
  AccountBinding(this._db, this._syncState);

  final AppDatabase _db;
  final SyncStateStore _syncState;

  /// Binds to [claims]; erases foreign data first. Returns whether it erased.
  Future<bool> bind(AccessClaims claims) {
    return _db.transaction(() async {
      final row = await _syncState.row();
      if (row.userId == claims.userId && row.region == claims.region) {
        return false;
      }
      final foreign = row.userId != null;
      if (foreign) {
        await _db.wipeAccountData();
      }
      await _syncState.bindAccount(claims.userId, claims.region);
      return foreign;
    });
  }

  @override
  Future<void> signingIn(AccessClaims claims) async {
    await bind(claims);
  }

  @override
  Future<void> signedOut() => _db.wipeAccountData();
}
