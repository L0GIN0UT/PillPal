import 'dart:convert';

import 'package:drift/drift.dart';

import '../api/json.dart';
import '../api/sync_api.dart';
import '../api/sync_dto.dart';
import '../clock.dart';
import '../config.dart';
import '../db/database.dart';
import '../db/sync_state_store.dart';
import '../repositories/local_writer.dart';
import 'server_state_applier.dart';

/// Rejection codes worth retrying: the device clock is ahead of the server.
const Set<String> transientRejections = {'clock_skew'};

/// Throws unless the local data is still bound to the account the sync run
/// started for (a sign-out may erase it while a request is in flight).
typedef AccountGuard = Future<void> Function();

/// Totals of one push.
class PushTotals {
  /// Accepted by the server.
  int pushed = 0;

  /// Superseded by server state.
  int adopted = 0;

  /// Permanently rejected and reconciled with the server.
  int parked = 0;

  /// Why pushing stopped early, if it did.
  String? stopCode;
}

class _BatchOutcome {
  bool skewed = false;
  final List<OutboxEntry> toReconcile = [];
}

/// Pushes the outbox in order and applies the per-mutation results.
///
/// * `applied` - the entry is dropped;
/// * `ignored_stale` / `rejected:key_conflict` - `current` is adopted;
/// * `rejected:parent_deleted`, or `parent_not_found` while the local parent
///   is a tombstone - deletes are final: the entry is dropped and the entity
///   deleted locally;
/// * `rejected:clock_skew` - the rest of the batch's results are not
///   processed (those entries stay for an idempotent replay); the entries
///   with future keys are re-keyed from the server-corrected clock and the
///   push retried once in this run, then it stops with `clock_skew`;
/// * any other rejection is permanent: the server's state is fetched (GET)
///   and applied - a create the server never stored is deleted locally - and
///   the entry is parked (kept with `last_error`, never pushed again).
class OutboxPusher {
  /// Creates a pusher.
  OutboxPusher({
    required AppDatabase db,
    required SyncApi api,
    required ServerStateApplier applier,
    required ServerClock serverClock,
    required SyncStateStore syncState,
  })  : _db = db,
        _api = api,
        _applier = applier,
        _serverClock = serverClock,
        _syncState = syncState;

  final AppDatabase _db;
  final SyncApi _api;
  final ServerStateApplier _applier;
  final ServerClock _serverClock;
  final SyncStateStore _syncState;

  /// Pushes until the outbox is empty or a transient rejection persists.
  Future<PushTotals> push(AccountGuard guard) async {
    final totals = PushTotals();
    var rekeyed = false;
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
      final outcome = await _db.transaction(() async {
        await guard();
        return _handleResults(batch, results, totals);
      });
      for (final entry in outcome.toReconcile) {
        await _reconcile(entry, guard);
        totals.parked++;
      }
      if (outcome.skewed) {
        if (rekeyed) {
          totals.stopCode = 'clock_skew';
        } else {
          await _rekeyFutureWrites(guard);
          rekeyed = true;
        }
      }
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

  Future<_BatchOutcome> _handleResults(
    List<OutboxEntry> batch,
    List<MutationResult> results,
    PushTotals totals,
  ) async {
    final outcome = _BatchOutcome();
    for (var i = 0; i < batch.length; i++) {
      final entry = batch[i];
      final result = results[i];
      if (result.id != entry.entityId ||
          result.entity.wire != entry.entityKind) {
        throw const FormatException('Push results out of order');
      }
      if (transientRejections.contains(result.code)) {
        await _recordFailure(entry, result.code);
        outcome.skewed = true;
        break; // later entries stay untouched; replaying them is safe
      }
      await _handleResult(entry, result, totals, outcome);
    }
    return outcome;
  }

  Future<void> _handleResult(
    OutboxEntry entry,
    MutationResult result,
    PushTotals totals,
    _BatchOutcome outcome,
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
    } else if (code == 'parent_deleted' ||
        (code == 'parent_not_found' &&
            await _applier.isParentDeleted(result.entity, result.id))) {
      await _drop(entry);
      await _applier.markDeleted(result.entity, result.id, _nowMicros());
      totals.adopted++;
    } else if (result.status == MutationStatus.ignoredStale) {
      await _drop(entry); // stale without state: nothing to adopt
      totals.adopted++;
    } else {
      await _recordFailure(entry, code ?? 'rejected');
      outcome.toReconcile.add(entry);
    }
  }

  /// Adopts the server's state for a permanently rejected entry, then parks
  /// it. If the GET fails the entry stays unparked and is retried next run.
  Future<void> _reconcile(OutboxEntry entry, AccountGuard guard) async {
    final entity = SyncEntity.fromWire(entry.entityKind);
    final data = await _api.fetch(entity, entry.entityId);
    final deviceId = await _syncState.deviceId();
    await _db.transaction(() async {
      await guard();
      await (_db.update(_db.outbox)..where((row) => row.seq.equals(entry.seq)))
          .write(const OutboxCompanion(parked: Value(true)));
      if (data == null) {
        // Never stored (or gone): the local row must not linger unsynced.
        await _applier.markDeleted(entity, entry.entityId, _nowMicros());
      } else {
        await _applier.restore(
          entity,
          entry.entityId,
          data,
          keyMicros: entry.clientUpdatedAt,
          device: deviceId,
        );
      }
    });
  }

  /// Moves every pending key that is ahead of the corrected clock to
  /// `now + n µs` (in outbox order, so per-entity order holds) and lowers the
  /// entity rows' keys to match, so later edits are not skewed either.
  /// Dose times ahead of the clock are clamped to it.
  Future<void> _rekeyFutureWrites(AccountGuard guard) async {
    final now = _nowMicros();
    await _db.transaction(() async {
      await guard();
      final rows = await (_db.select(_db.outbox)
            ..where(
              (row) =>
                  row.parked.equals(false) &
                  row.clientUpdatedAt.isBiggerThanValue(now),
            )
            ..orderBy([(row) => OrderingTerm.asc(row.seq)]))
          .get();
      var next = now;
      final latest = <String, (String, int)>{};
      for (final row in rows) {
        next++;
        await (_db.update(_db.outbox)..where((r) => r.seq.equals(row.seq)))
            .write(
          OutboxCompanion(
            clientUpdatedAt: Value(next),
            payload: Value(await _clampDoseTime(row, now)),
          ),
        );
        latest[row.entityId] = (row.entityKind, next);
      }
      for (final MapEntry(key: id, value: (kind, key)) in latest.entries) {
        await _lowerEntityKey(kind, id, key, now);
      }
    });
  }

  Future<String?> _clampDoseTime(OutboxEntry row, int nowMicros) async {
    final payload = row.payload;
    if (row.entityKind != SyncEntity.doseEvent.wire || payload == null) {
      return payload;
    }
    final data = Map<String, Object?>.of(asJsonMap(jsonDecode(payload), 'dose'));
    final at = DateTime.tryParse('${data['at']}');
    if (at == null || at.microsecondsSinceEpoch <= nowMicros) {
      return payload;
    }
    data['at'] = instantToJson(microsToInstant(nowMicros));
    await (_db.update(_db.doseEvents)..where((r) => r.id.equals(row.entityId)))
        .write(DoseEventsCompanion(at: Value(nowMicros)));
    return jsonEncode(data);
  }

  Future<void> _lowerEntityKey(String kind, String id, int key, int now) async {
    final value = Value(key);
    switch (SyncEntity.fromWire(kind)) {
      case SyncEntity.profile:
        await (_db.update(_db.profiles)
              ..where((r) =>
                  r.id.equals(id) & r.clientUpdatedAt.isBiggerThanValue(now)))
            .write(ProfilesCompanion(clientUpdatedAt: value));
      case SyncEntity.medication:
        await (_db.update(_db.medications)
              ..where((r) =>
                  r.id.equals(id) & r.clientUpdatedAt.isBiggerThanValue(now)))
            .write(MedicationsCompanion(clientUpdatedAt: value));
      case SyncEntity.schedule:
        await (_db.update(_db.schedules)
              ..where((r) =>
                  r.id.equals(id) & r.clientUpdatedAt.isBiggerThanValue(now)))
            .write(SchedulesCompanion(clientUpdatedAt: value));
      case SyncEntity.doseEvent:
        break; // immutable: the key lives only in the outbox
    }
  }

  int _nowMicros() => _serverClock.now().microsecondsSinceEpoch;

  Future<void> _drop(OutboxEntry entry) async {
    await (_db.delete(_db.outbox)..where((row) => row.seq.equals(entry.seq)))
        .go();
  }

  Future<void> _recordFailure(OutboxEntry entry, String? code) async {
    await (_db.update(_db.outbox)..where((row) => row.seq.equals(entry.seq)))
        .write(
      OutboxCompanion(
        attempts: Value(entry.attempts + 1),
        lastError: Value(code),
      ),
    );
  }
}
