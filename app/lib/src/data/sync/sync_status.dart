import 'package:flutter/foundation.dart';

/// What the sync engine is doing.
enum SyncPhase {
  /// Not running; the last run (if any) succeeded.
  idle,

  /// A run is in progress.
  syncing,

  /// The last run failed; see [SyncStatus.errorCode].
  error,
}

/// Observable sync state for the UI.
@immutable
class SyncStatus {
  /// Creates a status.
  const SyncStatus({
    this.phase = SyncPhase.idle,
    this.lastSuccessAt,
    this.errorCode,
    this.parkedCount = 0,
  });

  /// Current phase.
  final SyncPhase phase;

  /// When the last run completed successfully.
  final DateTime? lastSuccessAt;

  /// Error code of the last failed run (`network_error`, `clock_skew`,
  /// `token_reused`, ...); null unless [phase] is [SyncPhase.error].
  final String? errorCode;

  /// Local changes the server rejected permanently (kept in the outbox).
  final int parkedCount;

  /// Returns a copy with the given fields replaced; [errorCode] is cleared
  /// unless given.
  SyncStatus copyWith({
    SyncPhase? phase,
    DateTime? lastSuccessAt,
    String? errorCode,
    int? parkedCount,
  }) {
    return SyncStatus(
      phase: phase ?? this.phase,
      lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
      errorCode: errorCode,
      parkedCount: parkedCount ?? this.parkedCount,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SyncStatus &&
      other.phase == phase &&
      other.lastSuccessAt == lastSuccessAt &&
      other.errorCode == errorCode &&
      other.parkedCount == parkedCount;

  @override
  int get hashCode => Object.hash(phase, lastSuccessAt, errorCode, parkedCount);

  @override
  String toString() => 'SyncStatus($phase, error: $errorCode)';
}

/// Summary of one sync run.
@immutable
class SyncReport {
  /// Creates a report.
  const SyncReport({
    this.pushed = 0,
    this.adopted = 0,
    this.parked = 0,
    this.pulled = 0,
    this.signedOut = false,
    this.errorCode,
  });

  /// Outbox entries accepted by the server.
  final int pushed;

  /// Outbox entries superseded by server state (ignored_stale, key_conflict,
  /// parent_deleted).
  final int adopted;

  /// Outbox entries permanently rejected in this run.
  final int parked;

  /// Pulled changes applied or skipped.
  final int pulled;

  /// Nothing was done because no session is stored.
  final bool signedOut;

  /// Why the run stopped early, if it did.
  final String? errorCode;

  /// Whether the run completed without error.
  bool get ok => errorCode == null;
}
