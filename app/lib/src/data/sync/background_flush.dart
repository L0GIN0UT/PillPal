import 'dart:async';

import 'package:http/http.dart' as http;

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../api/sync_api.dart';
import '../auth/access_claims.dart';
import '../auth/token_store.dart';
import '../clock.dart';
import '../config.dart';
import '../db/database.dart';
import '../db/sync_state_store.dart';
import 'sync_engine.dart';
import 'sync_lease.dart';
import 'sync_status.dart';

/// Queues a background job that flushes the outbox of [userId] once the
/// network is there (WorkManager on Android).
abstract interface class BackgroundFlushScheduler {
  /// Enqueues one flush for the account [userId] (an opaque id).
  Future<void> enqueue(String userId);
}

/// Queues a flush for the account the local data is bound to; nothing
/// without one (signed out: the outbox is gone).
Future<void> enqueueFlushAfterAction({
  required SyncStateStore syncState,
  required BackgroundFlushScheduler scheduler,
}) async {
  final userId = await syncState.boundUserId();
  if (userId != null) {
    await scheduler.enqueue(userId);
  }
}

/// How a background flush ended; [retryLater] is the only one a job should
/// be retried for.
enum BackgroundFlushOutcome {
  /// The outbox was pushed.
  flushed,

  /// There was nothing to push (no request was made).
  nothingPending,

  /// No session is stored.
  signedOut,

  /// The session or the local data belongs to another account than the job
  /// was queued for: nothing was sent.
  accountChanged,

  /// Offline, the lease was busy, a server hiccup: try again later.
  retryLater,

  /// A permanent failure (rejected session, bug): the app flushes at its
  /// next start.
  failed,
}

/// Session events in a background engine: it never binds or erases
/// accounts. A refresh must be for the account the data is bound to; the
/// main app handles sign-in and sign-out.
class BackgroundSession implements SessionListener {
  /// Creates the listener.
  BackgroundSession(this._syncState);

  final SyncStateStore _syncState;

  @override
  Future<void> signingIn(AccessClaims claims) async {
    if (await _syncState.boundUserId() != claims.userId) {
      throw const ApiException(ApiException.accountChanged, 0);
    }
  }

  @override
  Future<void> signedOut() async {}
}

/// The push-only flush after a notification action (ADR 0001, addendum
/// 3.7): the outbox in its order, through the sync lease, and nothing else -
/// never a pull, so no relatives' data is fetched in the background.
///
/// Guarded by the account: the job carries the account it was queued for,
/// and nothing is sent unless the stored session and the local binding are
/// both that account (a sign-out or another sign-in erased the outbox the
/// job was about).
class BackgroundFlush {
  /// Creates a flush over a background [engine].
  BackgroundFlush({
    required AppDatabase db,
    required TokenStore tokens,
    required SyncStateStore syncState,
    required SyncEngine engine,
    this.refreshAllowed = true,
    Clock clock = systemClock,
  })  : _db = db,
        _tokens = tokens,
        _syncState = syncState,
        _engine = engine,
        _clock = clock;

  /// How close to its expiry an access token is treated as expired when
  /// [refreshAllowed] is false.
  static const Duration expiryMargin = Duration(seconds: 60);

  /// Whether this flush may rotate the refresh token. False in the iOS
  /// background window: a rotation whose response is lost to a suspension
  /// would leave the device with a spent token, so it is left to the next
  /// app start (which runs without a deadline).
  final bool refreshAllowed;

  /// Error codes worth another attempt.
  static const Set<String> retryable = {
    ApiException.networkError,
    SyncEngine.syncBusy,
    SyncEngine.leaseLost,
    ApiException.refreshDeferred,
    'rate_limited',
    'retry_later',
  };

  final AppDatabase _db;
  final TokenStore _tokens;
  final SyncStateStore _syncState;
  final SyncEngine _engine;
  final Clock _clock;

  /// Pushes the outbox for [userId]; never throws.
  Future<BackgroundFlushOutcome> run({required String userId}) async {
    try {
      final stored = await _tokens.read();
      if (stored == null) {
        return BackgroundFlushOutcome.signedOut;
      }
      final claims = AccessClaims.fromToken(stored.accessToken);
      if (claims?.userId != userId ||
          await _syncState.boundUserId() != userId) {
        return BackgroundFlushOutcome.accountChanged;
      }
      if (!await _hasPending()) {
        return BackgroundFlushOutcome.nothingPending;
      }
      if (!refreshAllowed &&
          stored.accessExpiresAt.difference(_clock()) <= expiryMargin) {
        return BackgroundFlushOutcome.retryLater;
      }
      return _outcomeOf(await _engine.sync(pull: false));
    } on Object {
      // No details: they may carry medical data.
      return BackgroundFlushOutcome.failed;
    }
  }

  Future<bool> _hasPending() async {
    final row = await (_db.select(_db.outbox)
          ..where((entry) => entry.parked.equals(false))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  BackgroundFlushOutcome _outcomeOf(SyncReport report) {
    final code = report.errorCode;
    if (report.signedOut) {
      return BackgroundFlushOutcome.signedOut;
    }
    if (code == null) {
      return BackgroundFlushOutcome.flushed;
    }
    if (code == SyncEngine.accountChanged) {
      return BackgroundFlushOutcome.accountChanged;
    }
    if (retryable.contains(code) || code.startsWith('http_5')) {
      return BackgroundFlushOutcome.retryLater;
    }
    return BackgroundFlushOutcome.failed;
  }
}

/// Runs [flush] for at most [deadline]. On timeout [abort] (closing the HTTP
/// client) ends the request in flight and the flush is awaited for up to
/// [grace] more, so the lease is released and nothing still uses the database
/// when the caller closes it. Never throws.
Future<BackgroundFlushOutcome> runWithDeadline(
  Future<BackgroundFlushOutcome> Function() flush, {
  required Duration deadline,
  required void Function() abort,
  Duration grace = const Duration(seconds: 3),
}) async {
  final running = flush();
  try {
    return await running.timeout(deadline);
  } on TimeoutException {
    abort();
  }
  try {
    return await running.timeout(grace);
  } on TimeoutException {
    return BackgroundFlushOutcome.failed;
  }
}

/// Builds the push-only stack in this isolate/engine (no Riverpod) and
/// flushes the outbox for [userId]. With [db] (the notification handler's
/// own connection) nothing is opened or closed here.
///
/// With a [deadline] (iOS: the background task window) the flush never
/// outlives it: the lease wait is capped by it, a request in flight is
/// aborted at the deadline and awaited before returning, and [refresh] is
/// off, so the refresh token is never rotated in a window that can end in the
/// middle of the request. Without one (an Android job) the lease wait is
/// [SyncLease.backgroundMaxWait].
Future<BackgroundFlushOutcome> runBackgroundFlush({
  required String userId,
  AppDatabase? db,
  Duration? deadline,
  bool refresh = true,
}) async {
  final database = db ?? AppDatabase.open();
  final client = http.Client();
  SyncEngine? engine;
  try {
    final syncState = SyncStateStore(database, newUuid);
    final tokens = SecureTokenStore(
      isFreshInstall: syncState.claimSecureStorageReset,
    );
    final lease = SyncLease(
      db: database,
      clock: systemClock,
      newId: newUuid,
      maxWait: deadline ?? SyncLease.backgroundMaxWait,
    );
    final serverClock = ServerClock();
    final api = ApiClient(
      httpClient: client,
      config: ApiConfig.fromEnvironment(),
      tokens: tokens,
      deviceId: syncState.deviceId,
      serverClock: serverClock,
      session: BackgroundSession(syncState),
      lease: lease,
      refreshEnabled: refresh,
    );
    final created = SyncEngine(
      db: database,
      api: SyncApi(api),
      tokens: tokens,
      syncState: syncState,
      serverClock: serverClock,
      lease: lease,
    );
    engine = created;
    Future<BackgroundFlushOutcome> flush() => BackgroundFlush(
          db: database,
          tokens: tokens,
          syncState: syncState,
          engine: created,
          refreshAllowed: refresh,
        ).run(userId: userId);
    if (deadline == null) {
      return await flush();
    }
    return await runWithDeadline(
      flush,
      deadline: deadline,
      abort: client.close,
    );
  } on Object {
    return BackgroundFlushOutcome.failed;
  } finally {
    await engine?.dispose();
    client.close();
    if (db == null) {
      await database.close();
    }
  }
}
