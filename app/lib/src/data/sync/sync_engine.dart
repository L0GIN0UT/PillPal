import 'dart:async';

import '../api/api_exception.dart';
import '../api/sync_api.dart';
import '../auth/access_claims.dart';
import '../auth/token_store.dart';
import '../clock.dart';
import '../db/database.dart';
import '../db/sync_state_store.dart';
import 'outbox_pusher.dart';
import 'scoped_puller.dart';
import 'server_state_applier.dart';
import 'sync_lease.dart';
import 'sync_status.dart';

/// Offline-first sync: push the outbox in order ([OutboxPusher] documents the
/// result handling), then pull from the cursor.
///
/// Every run is for the account of the stored access token, and only if the
/// local data is bound to it ([AccountBinding] binds when tokens are saved;
/// the engine never binds). Otherwise - or if the binding changes while a
/// request is in flight (logout) - the run stops with `account_changed`.
/// Requests carry the account id, so [ApiClient] refuses to send them with
/// another account's token.
///
/// Pull is the scoped pull of [ScopedPuller]: one cursor per profile, every
/// page validated, applied and its cursors stored in one transaction.
/// Scopes of other people that were not pulled for the account-deletion
/// grace period are evicted at the start of every run, before any network
/// call. `410 cursor_expired` (journal compacted) triggers one full resync
/// from cursor 0.
///
/// With a [SyncLease] a run holds the lease of the whole app (all isolates)
/// from the token read to the last write: only one run pushes at a time,
/// and every transaction that applies results first renews the lease, so a
/// run whose lease lapsed discards its results (`lease_lost`) instead of
/// persisting them. A run that cannot get the lease in time ends with
/// `sync_busy`; whoever holds it is doing the same work.
class SyncEngine {
  /// Creates an engine.
  SyncEngine({
    required AppDatabase db,
    required SyncApi api,
    required TokenStore tokens,
    required SyncStateStore syncState,
    ServerClock? serverClock,
    SyncLease? lease,
  })  : _db = db,
        _tokens = tokens,
        _lease = lease,
        _syncState = syncState,
        _serverClock = serverClock ?? ServerClock(),
        _applier = ServerStateApplier(db) {
    _pusher = OutboxPusher(
      db: db,
      api: api,
      applier: _applier,
      serverClock: _serverClock,
      syncState: syncState,
    );
    _puller = ScopedPuller(
      db: db,
      api: api,
      applier: _applier,
      clock: _serverClock.deviceNow,
    );
  }

  /// The local data is not (or no longer) bound to the token's account.
  static const String accountChanged = ApiException.accountChanged;

  /// The stored access token is not a JWT with `sub` and `region`.
  static const String invalidToken = 'invalid_token';

  /// An unexpected failure (a bug); details are not logged (medical data).
  static const String unexpected = 'unexpected';

  /// Another runner kept the sync lease for the whole wait.
  static const String syncBusy = ApiException.syncBusy;

  /// The sync lease lapsed during the run; its results were discarded.
  static const String leaseLost = ApiException.leaseLost;

  final AppDatabase _db;
  final TokenStore _tokens;
  final SyncStateStore _syncState;
  final ServerClock _serverClock;
  final SyncLease? _lease;
  final ServerStateApplier _applier;
  late final OutboxPusher _pusher;
  late final ScopedPuller _puller;
  final StreamController<SyncStatus> _statusController =
      StreamController<SyncStatus>.broadcast();
  SyncStatus _status = const SyncStatus();
  Future<SyncReport>? _running;

  /// The latest status.
  SyncStatus get status => _status;

  /// Status updates.
  Stream<SyncStatus> get statusChanges => _statusController.stream;

  /// Runs one sync; concurrent calls share the run in progress. With
  /// [pull] false only the outbox is pushed.
  Future<SyncReport> sync({bool pull = true}) =>
      _running ??= _run(pull: pull).whenComplete(() => _running = null);

  /// Evicts the foreign scopes not pulled for too long (see
  /// [ScopedPuller.evictStaleScopes]); needs no network or sign-in, so the
  /// app runs it at start: a device that never syncs again must still lose
  /// the copies of relatives' data.
  Future<int> evictStaleScopes() => _puller.evictStaleScopes();

  /// Pushes pending changes (before a sign-out); errors are reported, not
  /// thrown.
  Future<void> flush() async {
    await sync(pull: false);
  }

  /// Number of outbox entries waiting to be pushed.
  Stream<int> watchPendingCount() {
    final query = _db.select(_db.outbox)
      ..where((row) => row.parked.equals(false));
    return query.watch().map((rows) => rows.length);
  }

  /// Releases the status stream.
  Future<void> dispose() => _statusController.close();

  Future<SyncReport> _run({required bool pull}) async {
    try {
      final lease = _lease;
      if (lease == null) {
        return await _runHolding(pull: pull);
      }
      return await lease.run((grant) => _runHolding(pull: pull, grant: grant));
    } on LeaseBusy {
      return _failed(syncBusy);
    } on LeaseLost {
      return _failed(leaseLost);
    } on ApiException catch (error) {
      return _failed(error.code);
    } on FormatException {
      return _failed(ApiException.invalidResponse);
    } on Object {
      // Never leave the status stuck in `syncing`; no details are logged
      // because they may contain medical data.
      return _failed(unexpected);
    }
  }

  Future<SyncReport> _runHolding({
    required bool pull,
    LeaseGrant? grant,
  }) async {
    // Read under the lease: another runner may have refreshed the session
    // while this one waited.
    final tokens = await _tokens.read();
    if (tokens == null) {
      return const SyncReport(signedOut: true);
    }
    _emit(_status.copyWith(phase: SyncPhase.syncing));
    final claims = AccessClaims.fromToken(tokens.accessToken);
    if (claims == null) {
      throw const ApiException(invalidToken, 0);
    }
    final userId = claims.userId;
    Future<void> guard() async {
      await _guard(userId);
      if (grant != null) {
        await _lease?.ensure(grant);
      }
    }

    await guard();
    await _puller.evictStaleScopes();
    final push = await _pusher.push(guard, userId);
    final pulled = pull ? await _puller.pullAll(guard, userId) : 0;
    final parkedTotal = await _parkedCount();
    final report = SyncReport(
      pushed: push.pushed,
      adopted: push.adopted,
      parked: push.parked,
      pulled: pulled,
      errorCode: push.stopCode,
    );
    if (report.ok) {
      final now = _serverClock.deviceNow();
      await _syncState.markSynced(now);
      _emit(SyncStatus(lastSuccessAt: now, parkedCount: parkedTotal));
    } else {
      _fail(report.errorCode, parkedTotal);
    }
    return report;
  }

  Future<void> _guard(String userId) async {
    if (await _syncState.boundUserId() != userId) {
      throw const ApiException(accountChanged, 0);
    }
  }

  SyncReport _failed(String code) {
    _fail(code, null);
    return SyncReport(errorCode: code);
  }

  void _fail(String? code, int? parkedTotal) {
    _emit(
      _status.copyWith(
        phase: SyncPhase.error,
        errorCode: code,
        parkedCount: parkedTotal,
      ),
    );
  }

  void _emit(SyncStatus status) {
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  Future<int> _parkedCount() async {
    final rows = await (_db.select(_db.outbox)
          ..where((row) => row.parked.equals(true)))
        .get();
    return rows.length;
  }
}
