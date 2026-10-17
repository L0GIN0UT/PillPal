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
import 'push_refusals.dart';
import 'server_state_applier.dart';

/// Rejection codes worth retrying: the device clock is ahead of the server.
const Set<String> transientRejections = {'clock_skew'};

/// How far below the server's future limit re-keyed writes land.
const Duration rekeyMargin = Duration(minutes: 1);

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
///   with keys beyond the server's window are re-keyed from the
///   server-corrected clock and the push retried once in this run, then it
///   stops with `clock_skew`;
/// * any other rejection of an own scope is permanent: the server's state is
///   fetched (GET) and applied - a create the server never stored is deleted
///   locally - and the entry is parked (kept with `last_error`, never pushed
///   again).
///
/// Entries of another person's scope (any role but `owner`, ADR 0006 §7)
/// never reach REST: the account may not read it, and a 404 would tombstone a
/// live entity for good. `forbidden`, `forbidden_field` and `read_only` apply
/// `current` (projected for the role) over the local row and drop the
/// entry; `not_found` and the parent errors hard-delete the entity and its
/// children and drop their entries; any other rejection only parks the
/// entry. An entry whose scope is no longer in `access_scopes` is dropped.
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
        _refusals = PushRefusals(applier),
        _serverClock = serverClock,
        _syncState = syncState;

  final AppDatabase _db;
  final SyncApi _api;
  final ServerStateApplier _applier;
  final PushRefusals _refusals;
  final ServerClock _serverClock;
  final SyncStateStore _syncState;

  /// Pushes until the outbox is empty or a transient rejection persists.
  Future<PushTotals> push(AccountGuard guard, String userId) async {
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
      // Still this account's run and, with a lease, still its holder (the
      // request below may take long): never send for a stale run.
      await guard();
      final results = await _api.push(
        [for (final e in batch) _mutation(e)],
        userId: userId,
      );
      final outcome = await _db.transaction(() async {
        await guard();
        return _handleResults(batch, results, totals);
      });
      for (final entry in outcome.toReconcile) {
        await _reconcile(entry, guard, userId);
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
      final role = await _roleOf(entry);
      if (role == null) {
        await _drop(entry); // its scope was evicted: the result is not ours
        continue;
      }
      await _handleResult(entry, result, role, totals, outcome);
    }
    return outcome;
  }

  /// The account's role in the entry's scope: owner for entries queued
  /// before schema version 4 (no profile id); null when the scope is gone.
  Future<String?> _roleOf(OutboxEntry entry) async {
    if (entry.profileId.isEmpty) {
      return ScopeRole.owner;
    }
    final scope = await (_db.select(_db.accessScopes)
          ..where((row) => row.profileId.equals(entry.profileId)))
        .getSingleOrNull();
    return scope?.role;
  }

  Future<void> _handleResult(
    OutboxEntry entry,
    MutationResult result,
    String role,
    PushTotals totals,
    _BatchOutcome outcome,
  ) async {
    final current = result.current;
    final code = result.code;
    final foreign = ScopeRole.isForeign(role);
    if (result.status == MutationStatus.applied) {
      await _drop(entry);
      totals.pushed++;
    } else if (accessRefusals.contains(code)) {
      await _drop(entry);
      await _refusals.adopt(result, role);
      totals.adopted++;
    } else if (foreign && missingRefusals.contains(code)) {
      await _drop(entry);
      await _refusals.evictMissing(result);
      totals.adopted++;
    } else if (current != null &&
        (result.status == MutationStatus.ignoredStale ||
            code == 'key_conflict')) {
      await _drop(entry); // first, so it no longer shields the entity
      await _applier.apply(result.entity, result.id, current, role: role);
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
    } else if (foreign) {
      await _recordFailure(entry, code ?? 'rejected');
      await _park(entry);
      totals.parked++;
    } else {
      await _recordFailure(entry, code ?? 'rejected');
      outcome.toReconcile.add(entry);
    }
  }

  /// Adopts the server's state for a permanently rejected entry, then parks
  /// it. If the GET fails the entry stays unparked and is retried next run.
  Future<void> _reconcile(
    OutboxEntry entry,
    AccountGuard guard,
    String userId,
  ) async {
    final entity = SyncEntity.fromWire(entry.entityKind);
    final data = await _api.fetch(entity, entry.entityId, userId: userId);
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

  /// Re-keys pending writes whose key the server cannot accept: keys more
  /// than `maxFutureSkew` ahead of the corrected clock move to
  /// `now + maxFutureSkew - rekeyMargin + n µs`. Keys within the window stay
  /// - they may legitimately follow a fast peer's key, and lowering them would
  /// turn a newer write into `ignored_stale`. Per entity, keys keep
  /// increasing in outbox order; entity rows get their new latest key, and
  /// dose times beyond the window are clamped to now.
  Future<void> _rekeyFutureWrites(AccountGuard guard) async {
    final now = _nowMicros();
    final limit = now + SyncLimits.maxFutureSkew.inMicroseconds;
    final base = limit - rekeyMargin.inMicroseconds;
    await _db.transaction(() async {
      await guard();
      final rows = await (_db.select(_db.outbox)
            ..where((row) => row.parked.equals(false))
            ..orderBy([(row) => OrderingTerm.asc(row.seq)]))
          .get();
      var n = 0;
      final lastKey = <String, int>{};
      final latest = <String, (String, int)>{};
      for (final row in rows) {
        var key = row.clientUpdatedAt;
        if (key > limit) {
          n++;
          final previous = lastKey[row.entityId];
          key = previous != null && previous >= base + n
              ? previous + 1
              : base + n;
          await (_db.update(_db.outbox)..where((r) => r.seq.equals(row.seq)))
              .write(
            OutboxCompanion(
              clientUpdatedAt: Value(key),
              payload: Value(await _clampDoseTime(row, now, limit)),
            ),
          );
          latest[row.entityId] = (row.entityKind, key);
        }
        lastKey[row.entityId] = key;
      }
      for (final MapEntry(key: id, value: (kind, key)) in latest.entries) {
        await _lowerEntityKey(kind, id, key, limit);
      }
    });
  }

  Future<String?> _clampDoseTime(
    OutboxEntry row,
    int nowMicros,
    int limitMicros,
  ) async {
    final payload = row.payload;
    if (row.entityKind != SyncEntity.doseEvent.wire || payload == null) {
      return payload;
    }
    final data =
        Map<String, Object?>.of(asJsonMap(jsonDecode(payload), 'dose'));
    final at = DateTime.tryParse('${data['at']}');
    if (at == null || at.microsecondsSinceEpoch <= limitMicros) {
      return payload;
    }
    data['at'] = instantToJson(microsToInstant(nowMicros));
    await (_db.update(_db.doseEvents)..where((r) => r.id.equals(row.entityId)))
        .write(DoseEventsCompanion(at: Value(nowMicros)));
    return jsonEncode(data);
  }

  Future<void> _lowerEntityKey(
    String kind,
    String id,
    int key,
    int limit,
  ) async {
    final value = Value(key);
    switch (SyncEntity.fromWire(kind)) {
      case SyncEntity.profile:
        await (_db.update(_db.profiles)
              ..where((r) =>
                  r.id.equals(id) & r.clientUpdatedAt.isBiggerThanValue(limit)))
            .write(ProfilesCompanion(clientUpdatedAt: value));
      case SyncEntity.medication:
        await (_db.update(_db.medications)
              ..where((r) =>
                  r.id.equals(id) & r.clientUpdatedAt.isBiggerThanValue(limit)))
            .write(MedicationsCompanion(clientUpdatedAt: value));
      case SyncEntity.schedule:
        await (_db.update(_db.schedules)
              ..where((r) =>
                  r.id.equals(id) & r.clientUpdatedAt.isBiggerThanValue(limit)))
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

  Future<void> _park(OutboxEntry entry) async {
    await (_db.update(_db.outbox)..where((row) => row.seq.equals(entry.seq)))
        .write(const OutboxCompanion(parked: Value(true)));
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
