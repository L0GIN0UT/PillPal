import 'dart:async';

import '../api/api_exception.dart';
import '../api/sync_api.dart';
import '../api/sync_dto.dart';
import '../auth/access_claims.dart';
import '../auth/token_store.dart';
import '../clock.dart';
import '../db/database.dart';
import '../db/sync_state_store.dart';
import 'outbox_pusher.dart';
import 'server_state_applier.dart';
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
/// Pull validates each page's cursor before applying it, applies the page
/// and stores its cursor in one transaction. `410 cursor_expired` (journal
/// compacted) triggers one full resync from cursor 0.
class SyncEngine {
  /// Creates an engine.
  SyncEngine({
    required AppDatabase db,
    required SyncApi api,
    required TokenStore tokens,
    required SyncStateStore syncState,
    ServerClock? serverClock,
  })  : _db = db,
        _api = api,
        _tokens = tokens,
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
  }

  /// The local data is not (or no longer) bound to the token's account.
  static const String accountChanged = ApiException.accountChanged;

  /// The stored access token is not a JWT with `sub` and `region`.
  static const String invalidToken = 'invalid_token';

  /// An unexpected failure (a bug); details are not logged (medical data).
  static const String unexpected = 'unexpected';

  final AppDatabase _db;
  final SyncApi _api;
  final TokenStore _tokens;
  final SyncStateStore _syncState;
  final ServerClock _serverClock;
  final ServerStateApplier _applier;
  late final OutboxPusher _pusher;
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
      Future<void> guard() => _guard(userId);
      await guard();
      final push = await _pusher.push(guard, userId);
      final pulled = pull ? await _pullAll(guard, userId) : 0;
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

  Future<int> _pullAll(AccountGuard guard, String userId) async {
    var cursor = await _syncState.cursor();
    var count = 0;
    var resynced = false;
    while (true) {
      final PullPage page;
      try {
        page = await _api.pull(cursor: cursor, userId: userId);
      } on ApiException catch (error) {
        if (error.status != 410 || resynced) {
          rethrow;
        }
        await _db.transaction(() async {
          await guard();
          await _db.resetForFullResync();
        });
        cursor = 0;
        resynced = true;
        continue;
      }
      // Checked before applying: a cursor that does not advance would loop.
      if (page.nextCursor < cursor ||
          (page.hasMore && page.nextCursor <= cursor)) {
        throw const ApiException(ApiException.invalidResponse, 200);
      }
      await _db.transaction(() async {
        await guard();
        for (final change in page.changes) {
          await _applier.apply(change.entity, change.id, change.state);
        }
        await _syncState.saveCursor(page.nextCursor);
      });
      count += page.changes.length;
      if (!page.hasMore) {
        return count;
      }
      cursor = page.nextCursor;
    }
  }
}
