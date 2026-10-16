import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../api/api_exception.dart';
import '../api/json.dart';
import '../api/sync_api.dart';
import '../api/sync_dto.dart';
import '../auth/token_store.dart';
import '../clock.dart';
import '../config.dart';
import '../db/database.dart';
import '../db/sync_state_store.dart';
import '../repositories/local_writer.dart';
import 'server_state_applier.dart';
import 'sync_status.dart';

/// Rejection codes worth retrying unchanged on a later run (the device clock
/// may be corrected). The push stops at the first one so later mutations are
/// not applied ahead of it.
const Set<String> transientRejections = {'clock_skew'};

/// Offline-first sync: push the outbox in order, then pull from the cursor.
///
/// Push result handling, per mutation:
/// * `applied` - the outbox entry is dropped;
/// * `ignored_stale`, or `rejected/key_conflict` - the server state in
///   `current` is adopted (see [ServerStateApplier]) and the entry dropped;
/// * `rejected/parent_deleted` - the parent is a tombstone and deletes are
///   final: the entry is dropped and the entity marked deleted locally;
/// * `rejected` with a [transientRejections] code - kept (attempts + 1,
///   `last_error`), and pushing stops for this run; the pull still runs;
/// * any other rejection is permanent - the entry is parked: kept with its
///   `last_error` for inspection, never pushed again, and no longer shields
///   the entity from pulled server state.
///
/// Pull applies each page and stores its cursor in one transaction.
class SyncEngine {
  /// Creates an engine.
  SyncEngine({
    required AppDatabase db,
    required SyncApi api,
    required TokenStore tokens,
    required SyncStateStore syncState,
    Clock clock = systemClock,
  })  : _db = db,
        _api = api,
        _tokens = tokens,
        _syncState = syncState,
        _clock = clock,
        _applier = ServerStateApplier(db);

  final AppDatabase _db;
  final SyncApi _api;
  final TokenStore _tokens;
  final SyncStateStore _syncState;
  final Clock _clock;
  final ServerStateApplier _applier;
  final StreamController<SyncStatus> _statusController =
      StreamController<SyncStatus>.broadcast();
  SyncStatus _status = const SyncStatus();
  Future<SyncReport>? _running;

  /// The latest status.
  SyncStatus get status => _status;

  /// Status updates.
  Stream<SyncStatus> get statusChanges => _statusController.stream;

  /// Runs one sync; concurrent calls share the run in progress.
  Future<SyncReport> sync() =>
      _running ??= _run().whenComplete(() => _running = null);

  /// Number of outbox entries waiting to be pushed.
  Stream<int> watchPendingCount() {
    final query = _db.select(_db.outbox)
      ..where((row) => row.parked.equals(false));
    return query.watch().map((rows) => rows.length);
  }

  /// Releases the status stream.
  Future<void> dispose() => _statusController.close();

  Future<SyncReport> _run() async {
    if (await _tokens.read() == null) {
      return const SyncReport(signedOut: true);
    }
    _emit(_status.copyWith(phase: SyncPhase.syncing));
    try {
      final push = await _pushAll();
      final pulled = await _pullAll();
      final parkedTotal = await _parkedCount();
      final report = SyncReport(
        pushed: push.pushed,
        adopted: push.adopted,
        parked: push.parked,
        pulled: pulled,
        errorCode: push.stopCode,
      );
      if (report.ok) {
        final now = _clock();
        await _syncState.markSynced(now);
        _emit(SyncStatus(lastSuccessAt: now, parkedCount: parkedTotal));
      } else {
        _fail(report.errorCode, parkedTotal);
      }
      return report;
    } on ApiException catch (error) {
      _fail(error.code, null);
      return SyncReport(errorCode: error.code);
    } on FormatException {
      _fail(ApiException.invalidResponse, null);
      return const SyncReport(errorCode: ApiException.invalidResponse);
    }
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

  // -- push ------------------------------------------------------------------

  Future<_PushTotals> _pushAll() async {
    final totals = _PushTotals();
    while (totals.stopCode == null) {
      final batch = await (_db.select(_db.outbox)
            ..where((row) => row.parked.equals(false))
            ..orderBy([(row) => OrderingTerm.asc(row.seq)])
            ..limit(SyncLimits.pushBatch))
          .get();
      if (batch.isEmpty) {
        break;
      }
      final results = await _api.push([for (final e in batch) _mutation(e)]);
      await _db.transaction(() => _handleResults(batch, results, totals));
    }
    return totals;
  }

  Mutation _mutation(OutboxEntry entry) {
    final payload = entry.payload;
    return Mutation(
      entity: SyncEntity.fromWire(entry.entityKind),
      op: SyncOp.fromWire(entry.op),
      id: entry.entityId,
      data: payload == null ? null : asJsonMap(jsonDecode(payload), 'payload'),
      clientUpdatedAt: microsToInstant(entry.clientUpdatedAt),
    );
  }

  Future<void> _handleResults(
    List<OutboxEntry> batch,
    List<MutationResult> results,
    _PushTotals totals,
  ) async {
    for (var i = 0; i < batch.length; i++) {
      final entry = batch[i];
      final result = results[i];
      if (result.id != entry.entityId ||
          result.entity.wire != entry.entityKind) {
        throw const ApiException(ApiException.invalidResponse, 200);
      }
      await _handleResult(entry, result, totals);
    }
  }

  Future<void> _handleResult(
    OutboxEntry entry,
    MutationResult result,
    _PushTotals totals,
  ) async {
    final current = result.current;
    final code = result.code;
    if (result.status == MutationStatus.applied) {
      await _drop(entry);
      totals.pushed++;
    } else if (current != null &&
        (result.status == MutationStatus.ignoredStale ||
            code == 'key_conflict')) {
      await _drop(entry); // first, so it no longer shields the entity
      await _applier.apply(result.entity, result.id, current);
      totals.adopted++;
    } else if (code == 'parent_deleted') {
      await _drop(entry);
      await _applier.markDeleted(
        result.entity,
        result.id,
        _clock().microsecondsSinceEpoch,
      );
      totals.adopted++;
    } else if (result.status == MutationStatus.ignoredStale) {
      await _drop(entry); // stale without state: nothing to adopt
      totals.adopted++;
    } else if (transientRejections.contains(code)) {
      await _recordFailure(entry, code, parked: false);
      totals.stopCode ??= code;
    } else {
      await _recordFailure(entry, code ?? 'rejected', parked: true);
      totals.parked++;
    }
  }

  Future<void> _drop(OutboxEntry entry) async {
    await (_db.delete(_db.outbox)..where((row) => row.seq.equals(entry.seq)))
        .go();
  }

  Future<void> _recordFailure(
    OutboxEntry entry,
    String? code, {
    required bool parked,
  }) async {
    await (_db.update(_db.outbox)..where((row) => row.seq.equals(entry.seq)))
        .write(
      OutboxCompanion(
        attempts: Value(entry.attempts + 1),
        lastError: Value(code),
        parked: Value(parked),
      ),
    );
  }

  Future<int> _parkedCount() async {
    final rows = await (_db.select(_db.outbox)
          ..where((row) => row.parked.equals(true)))
        .get();
    return rows.length;
  }

  // -- pull ------------------------------------------------------------------

  Future<int> _pullAll() async {
    var cursor = await _syncState.cursor();
    var count = 0;
    while (true) {
      final page = await _api.pull(cursor: cursor);
      await _db.transaction(() async {
        for (final change in page.changes) {
          await _applier.apply(change.entity, change.id, change.state);
        }
        await _syncState.saveCursor(page.nextCursor);
      });
      count += page.changes.length;
      if (!page.hasMore) {
        return count;
      }
      if (page.nextCursor <= cursor) {
        throw const ApiException(ApiException.invalidResponse, 200);
      }
      cursor = page.nextCursor;
    }
  }
}

class _PushTotals {
  int pushed = 0;
  int adopted = 0;
  int parked = 0;
  String? stopCode;
}
