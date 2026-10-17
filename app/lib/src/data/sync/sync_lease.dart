import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show immutable;

import '../clock.dart';
import '../db/database.dart';

/// Proof of holding the [SyncLease]: the holder's id and the epoch of its
/// acquisition. Both must still match the row for the holder to persist
/// anything (fencing).
@immutable
class LeaseGrant {
  /// Creates a grant.
  const LeaseGrant({required this.holder, required this.epoch});

  /// Random id of the holder.
  final String holder;

  /// Acquisition counter of the lease at that time.
  final int epoch;

  @override
  bool operator ==(Object other) =>
      other is LeaseGrant && other.holder == holder && other.epoch == epoch;

  @override
  int get hashCode => Object.hash(holder, epoch);
}

/// The holder's lease lapsed (or was taken over): its results must be
/// discarded, not persisted.
class LeaseLost implements Exception {
  /// Creates the exception.
  const LeaseLost();

  @override
  String toString() => 'LeaseLost';
}

/// Another holder kept the lease for the whole wait.
class LeaseBusy implements Exception {
  /// Creates the exception.
  const LeaseBusy();

  @override
  String toString() => 'LeaseBusy';
}

/// The one lease of everything that talks to the account's session or
/// applies sync results: outbox push and token refresh, in the main isolate
/// and in background engines alike (ADR 0001, addendum 3.7).
///
/// The state is one drift row ([SyncLeases]), changed with single guarded
/// statements, so acquisition, renewal and release are atomic between
/// isolates. Rules:
///
/// * [ttl] is longer than the HTTP timeout of a request and its body
///   (`ApiConfig.requestTimeout`, twice), and holders renew ([ensure])
///   between requests; a holder that dies frees the lease by expiry.
/// * Fencing: before persisting tokens or applying results the holder calls
///   [ensure] (inside the same transaction as the write). A holder whose
///   lease lapsed gets [LeaseLost] and discards what it fetched; whoever
///   holds the lease now re-reads the tokens and redoes the work (the
///   server's refresh reuse window answers a repeated rotation with the same
///   pair).
/// * [run] is re-entrant inside the same zone, so a sync run that holds the
///   lease can refresh the session without asking again.
class SyncLease {
  /// Creates a lease handle. Every isolate/engine has its own; they meet in
  /// the database.
  SyncLease({
    required AppDatabase db,
    required Clock clock,
    required IdGenerator newId,
    this.ttl = defaultTtl,
    this.pollInterval = defaultPollInterval,
    this.maxWait = defaultMaxWait,
    Future<void> Function(Duration)? delay,
  })  : _db = db,
        _clock = clock,
        _newId = newId,
        _delay = delay ?? Future<void>.delayed;

  /// Longer than two request timeouts (response, then body) of 30 s.
  static const Duration defaultTtl = Duration(seconds: 90);

  /// How often a waiting runner looks at the lease.
  static const Duration defaultPollInterval = Duration(milliseconds: 250);

  /// How long a runner waits before giving up with [LeaseBusy].
  static const Duration defaultMaxWait = Duration(seconds: 100);

  static const int _rowId = 1;
  static final Object _zoneKey = Object();

  final AppDatabase _db;
  final Clock _clock;
  final IdGenerator _newId;
  final Future<void> Function(Duration) _delay;

  /// How long a lease lives without renewal.
  final Duration ttl;

  /// Polling period while waiting.
  final Duration pollInterval;

  /// Default wait of [acquire] and [run].
  final Duration maxWait;

  int _micros(DateTime time) => time.toUtc().microsecondsSinceEpoch;

  /// Takes the lease if it is free or lapsed; null if someone holds it.
  Future<LeaseGrant?> tryAcquire() {
    return _db.transaction(() async {
      final now = _micros(_clock());
      final holder = _newId();
      await _db.customStatement(
        'INSERT OR IGNORE INTO sync_leases (id, epoch, expires_at) '
        'VALUES ($_rowId, 0, 0)',
      );
      final taken = await _db.customUpdate(
        'UPDATE sync_leases SET holder = ?, epoch = epoch + 1, '
        'expires_at = ? WHERE id = $_rowId '
        'AND (holder IS NULL OR expires_at <= ?)',
        variables: [
          Variable.withString(holder),
          Variable.withInt(now + ttl.inMicroseconds),
          Variable.withInt(now),
        ],
      );
      if (taken == 0) {
        return null;
      }
      final row = await _row();
      return LeaseGrant(holder: holder, epoch: row!.epoch);
    });
  }

  /// Waits (polling, up to [maxWait]) for the lease; throws [LeaseBusy].
  Future<LeaseGrant> acquire({Duration? maxWait}) async {
    final deadline = _clock().add(maxWait ?? this.maxWait);
    while (true) {
      final grant = await tryAcquire();
      if (grant != null) {
        return grant;
      }
      if (!_clock().isBefore(deadline)) {
        throw const LeaseBusy();
      }
      await _delay(pollInterval);
    }
  }

  Future<SyncLeaseRow?> _row() {
    return (_db.select(_db.syncLeases)..where((row) => row.id.equals(_rowId)))
        .getSingleOrNull();
  }

  /// Whether [grant] is still the live lease (read only).
  Future<bool> holds(LeaseGrant grant) async {
    final row = await _row();
    return row != null &&
        row.holder == grant.holder &&
        row.epoch == grant.epoch &&
        row.expiresAt > _micros(_clock());
  }

  /// Renews [grant] for another [ttl], or throws [LeaseLost]. One guarded
  /// statement, so it is safe inside a transaction that persists results.
  Future<void> ensure(LeaseGrant grant) async {
    final now = _micros(_clock());
    final renewed = await _db.customUpdate(
      'UPDATE sync_leases SET expires_at = ? WHERE id = $_rowId '
      'AND holder = ? AND epoch = ? AND expires_at > ?',
      variables: [
        Variable.withInt(now + ttl.inMicroseconds),
        Variable.withString(grant.holder),
        Variable.withInt(grant.epoch),
        Variable.withInt(now),
      ],
    );
    if (renewed == 0) {
      throw const LeaseLost();
    }
  }

  /// Frees the lease if [grant] still holds it; a stale holder changes
  /// nothing.
  Future<void> release(LeaseGrant grant) async {
    await _db.customUpdate(
      'UPDATE sync_leases SET holder = NULL, expires_at = 0 '
      'WHERE id = $_rowId AND holder = ? AND epoch = ?',
      variables: [
        Variable.withString(grant.holder),
        Variable.withInt(grant.epoch),
      ],
    );
  }

  /// Runs [body] holding the lease and releases it afterwards. Inside a
  /// [run] of this same lease the grant is reused (no second acquisition).
  /// Throws [LeaseBusy] if the lease cannot be had within [maxWait].
  Future<T> run<T>(
    Future<T> Function(LeaseGrant grant) body, {
    Duration? maxWait,
  }) async {
    final held = Zone.current[_zoneKey];
    if (held is _Held && identical(held.lease, this)) {
      return body(held.grant);
    }
    final grant = await acquire(maxWait: maxWait);
    try {
      final zone = Zone.current.fork(
        zoneValues: {_zoneKey: _Held(this, grant)},
      );
      return await zone.run(() => body(grant));
    } finally {
      await release(grant);
    }
  }
}

class _Held {
  const _Held(this.lease, this.grant);

  final SyncLease lease;
  final LeaseGrant grant;
}
