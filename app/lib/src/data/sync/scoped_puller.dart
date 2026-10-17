import 'package:drift/drift.dart';

import '../api/api_exception.dart';
import '../api/sync_api.dart';
import '../api/sync_dto.dart';
import '../clock.dart';
import '../config.dart';
import '../db/database.dart';
import 'outbox_pusher.dart' show AccountGuard;
import 'server_state_applier.dart';

/// The scope id a device with no known scope sends in its first request: the
/// protocol needs at least one cursor, `scopes` of the answer lists every
/// accessible scope whatever was requested, and an unknown id only lands in
/// `revoked`.
const String probeScopeId = '00000000-0000-0000-0000-000000000000';

/// Most passes over the scopes in one run: each pass pulls the scopes the
/// previous one discovered (at most `MAX_ACCESS_SCOPES_PER_USER`, 100).
const int maxPullPasses = 10;

/// The scoped pull (ADR 0006 §2, §7): one cursor per scope, groups of at
/// most [SyncLimits.pullScopes] scopes each pulled to completion, then the
/// scopes the answers revealed.
///
/// Every page is validated first (cursors never move back, and a page with
/// more to come must advance one), then applied with its cursors in one
/// transaction:
/// * a local scope that is in `revoked` or missing from `scopes` is evicted
///   (rows, outbox entries, device setting) - except an own scope that still
///   has pending local writes: its creation has not reached the server yet;
/// * a scope whose role changed is evicted before the page is applied, its
///   changes in the page are dropped and its cursor restarts at 0 (the new
///   role projects differently, or the profile moved: ADR 0005 §5);
/// * changes of scopes that are not (or no longer) in `access_scopes` are
///   discarded;
/// * a scope first seen in `scopes` is added at cursor 0 and pulled in the
///   next pass.
class ScopedPuller {
  /// Creates a puller.
  ScopedPuller({
    required AppDatabase db,
    required SyncApi api,
    required ServerStateApplier applier,
    required Clock clock,
  })  : _db = db,
        _api = api,
        _applier = applier,
        _clock = clock;

  final AppDatabase _db;
  final SyncApi _api;
  final ServerStateApplier _applier;
  final Clock _clock;

  /// Pulls everything; returns the number of changes received. Throws
  /// [ApiException] for transport and server errors, [FormatException] for a
  /// page the client cannot interpret.
  Future<int> pullAll(AccountGuard guard, String userId) async {
    final run = _Run();
    for (var pass = 0; pass < maxPullPasses; pass++) {
      run.discovered = false;
      final ids = [for (final row in await _scopeRows()) row.profileId];
      if (ids.isEmpty) {
        await _pullGroup(const [], guard, userId, run);
      }
      for (var start = 0; start < ids.length; start += SyncLimits.pullScopes) {
        final end = start + SyncLimits.pullScopes;
        await _pullGroup(
          ids.sublist(start, end > ids.length ? ids.length : end),
          guard,
          userId,
          run,
        );
      }
      if (!run.discovered) {
        break;
      }
    }
    return run.count;
  }

  /// Evicts every scope of another person that has not been pulled
  /// successfully for [SyncLimits.staleScopeAfter]; returns how many. The
  /// grace period of an account deletion is the longest a relative may keep
  /// a copy: the remote wipe of a device that never syncs is impossible.
  /// The age is measured with the device clock (the server's is not known
  /// offline): a clock set far back only delays the eviction.
  Future<int> evictStaleScopes() async {
    final cutoff = _clock()
        .toUtc()
        .subtract(SyncLimits.staleScopeAfter)
        .microsecondsSinceEpoch;
    return _db.transaction(() async {
      final stale = await (_db.select(_db.accessScopes)
            ..where(
              (row) =>
                  row.role.isNotValue(ScopeRole.owner) &
                  row.lastPulledAt.isSmallerThanValue(cutoff),
            ))
          .get();
      for (final row in stale) {
        await _db.evictScope(row.profileId);
      }
      return stale.length;
    });
  }

  Future<List<AccessScopeRow>> _scopeRows() {
    return (_db.select(_db.accessScopes)
          ..orderBy([(row) => OrderingTerm.asc(row.profileId)]))
        .get();
  }

  /// Pulls the scopes of [group] (empty: the first request of a device) to
  /// completion.
  Future<void> _pullGroup(
    List<String> group,
    AccountGuard guard,
    String userId,
    _Run run,
  ) async {
    while (true) {
      final request = await _request(group);
      if (request == null) {
        return; // every scope of the group was evicted meanwhile
      }
      final ScopedPullPage page;
      try {
        page = await _api.pullScoped(
          cursors: request.cursors,
          backfillUntil: request.backfillUntil,
          userId: userId,
        );
      } on ApiException catch (error) {
        if (error.status != 410 || run.resynced) {
          rethrow;
        }
        await _db.transaction(() async {
          await guard();
          await _db.resetForFullResync();
        });
        run.resynced = true;
        run.discovered = true; // every scope restarts from 0 in a new pass
        continue;
      }
      _checkProgress(request.cursors, page);
      await _db.transaction(() async {
        await guard();
        await _applyPage(request.cursors.keys.toSet(), page, run);
      });
      run.count += page.changes.length;
      if (!page.hasMore) {
        return;
      }
    }
  }

  Future<_Request?> _request(List<String> group) async {
    if (group.isEmpty) {
      return const _Request({probeScopeId: 0}, {});
    }
    final rows = await (_db.select(_db.accessScopes)
          ..where((row) => row.profileId.isIn(group)))
        .get();
    if (rows.isEmpty) {
      return null;
    }
    return _Request(
      {for (final row in rows) row.profileId: row.cursor},
      {
        for (final row in rows)
          if (row.backfillUntil != null) row.profileId: row.backfillUntil!,
      },
    );
  }

  /// A cursor that moves back, or a page with more to come that advances no
  /// scope, would corrupt the local state or loop: refused before applying.
  void _checkProgress(Map<String, int> sent, ScopedPullPage page) {
    var advanced = false;
    for (final scope in page.scopes) {
      final before = sent[scope.profileId];
      final after = scope.cursor;
      if (before == null || after == null) {
        continue;
      }
      if (after < before) {
        throw const ApiException(ApiException.invalidResponse, 200);
      }
      advanced = advanced || after > before;
    }
    if (page.hasMore && !advanced) {
      throw const ApiException(ApiException.invalidResponse, 200);
    }
  }

  Future<void> _applyPage(
    Set<String> requested,
    ScopedPullPage page,
    _Run run,
  ) async {
    final now = _clock().toUtc().microsecondsSinceEpoch;
    final rows = {
      for (final row in await _scopeRows()) row.profileId: row,
    };
    final roles = {for (final row in rows.values) row.profileId: row.role};
    final listed = {for (final scope in page.scopes) scope.profileId};
    final ended = [
      ...page.revoked,
      ...roles.keys.where((id) => !listed.contains(id)),
    ];
    for (final id in ended) {
      if (roles.containsKey(id) && await _mayEvict(id, roles[id]!)) {
        await _db.evictScope(id);
        roles.remove(id);
      }
    }
    final dropped = <String>{};
    for (final scope in page.scopes) {
      final role = roles[scope.profileId];
      if (role == null) {
        await _insertScope(scope, now);
        run.discovered = true;
      } else if (role != scope.role) {
        await _db.evictScope(scope.profileId);
        await _insertScope(scope, now);
        dropped.add(scope.profileId);
        // Pulled again from 0 in this run, whatever group it was in.
        run.discovered = true;
      } else {
        await _updateScope(
          rows[scope.profileId]!,
          scope,
          now,
          pulled: requested.contains(scope.profileId),
        );
      }
      roles[scope.profileId] = scope.role;
    }
    for (final change in page.changes) {
      final role = roles[change.scope];
      if (role == null ||
          dropped.contains(change.scope) ||
          !requested.contains(change.scope)) {
        continue;
      }
      await _applier.apply(change.entity, change.id, change.state, role: role);
    }
  }

  /// Whether the scope may be evicted now. An own scope with writes still
  /// waiting in the outbox may simply not have reached the server yet.
  Future<bool> _mayEvict(String profileId, String role) async {
    if (ScopeRole.isForeign(role)) {
      return true;
    }
    final pending = await (_db.select(_db.outbox)
          ..where(
            (row) => row.profileId.equals(profileId) & row.parked.equals(false),
          )
          ..limit(1))
        .get();
    return pending.isEmpty;
  }

  Future<void> _insertScope(PulledScope scope, int now) async {
    await _db.into(_db.accessScopes).insertOnConflictUpdate(
          AccessScopesCompanion.insert(
            profileId: scope.profileId,
            role: scope.role,
            kind: scope.kind,
            archived: Value(scope.archived),
            archivePurgeAfter: Value(_micros(scope.archivePurgeAfter)),
            ownerLastSeenAt: Value(_micros(scope.ownerLastSeenAt)),
            lastPulledAt: Value(now),
          ),
        );
  }

  /// Writes only what changed: every write to the scope row wakes the
  /// watchers of the own profile and the reminder triggers, and most pages
  /// change nothing but the pull time.
  Future<void> _updateScope(
    AccessScopeRow row,
    PulledScope scope,
    int now, {
    required bool pulled,
  }) async {
    // Only a requested scope has a cursor; the others keep theirs.
    final cursor = pulled ? scope.cursor : null;
    final archivePurgeAfter = _micros(scope.archivePurgeAfter);
    final ownerLastSeenAt = _micros(scope.ownerLastSeenAt);
    final lastPulled = row.lastPulledAt;
    final touch = pulled &&
        (lastPulled == null ||
            now - lastPulled >= SyncLimits.scopeTouchInterval.inMicroseconds);
    final cursorChanged = cursor != null && cursor != row.cursor;
    final backfillChanged = pulled && scope.backfillUntil != row.backfillUntil;
    final unchanged = scope.kind == row.kind &&
        scope.archived == row.archived &&
        archivePurgeAfter == row.archivePurgeAfter &&
        ownerLastSeenAt == row.ownerLastSeenAt &&
        !cursorChanged &&
        !backfillChanged &&
        !touch;
    if (unchanged) {
      return;
    }
    await (_db.update(_db.accessScopes)
          ..where((r) => r.profileId.equals(scope.profileId)))
        .write(
      AccessScopesCompanion(
        kind: Value(scope.kind),
        archived: Value(scope.archived),
        archivePurgeAfter: Value(archivePurgeAfter),
        ownerLastSeenAt: Value(ownerLastSeenAt),
        cursor: cursorChanged ? Value(cursor) : const Value.absent(),
        backfillUntil:
            backfillChanged ? Value(scope.backfillUntil) : const Value.absent(),
        lastPulledAt: touch ? Value(now) : const Value.absent(),
      ),
    );
  }

  int? _micros(DateTime? value) => value?.microsecondsSinceEpoch;
}

/// The state of one `pullAll`.
class _Run {
  int count = 0;
  bool discovered = false;
  bool resynced = false;
}

class _Request {
  const _Request(this.cursors, this.backfillUntil);

  final Map<String, int> cursors;
  final Map<String, int> backfillUntil;
}
