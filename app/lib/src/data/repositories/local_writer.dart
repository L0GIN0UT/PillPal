import 'dart:convert';

import 'package:drift/drift.dart';

import '../api/json.dart';
import '../api/sync_dto.dart';
import '../clock.dart';
import '../db/database.dart';
import '../db/sync_state_store.dart';

/// A local write the data layer refuses; [code] mirrors the server's codes.
class DataException implements Exception {
  /// Creates an exception; [field] names the offending input, if any.
  const DataException(this.code, {this.field});

  /// A field breaks the server's rules (see `validation.dart`).
  static const String validationError = 'validation_error';

  /// Unknown or foreign id.
  static const String notFound = 'not_found';

  /// The entity is a tombstone (deletes are final).
  static const String deleted = 'deleted';

  /// The parent does not exist locally.
  static const String parentNotFound = 'parent_not_found';

  /// The parent is a tombstone.
  static const String parentDeleted = 'parent_deleted';

  /// Rule rejected by `ScheduleRule.fromJson`.
  static const String invalidRule = 'invalid_rule';

  /// The `self` profile cannot be deleted.
  static const String selfProfileProtected = 'self_profile_protected';

  /// `undo` must target a non-undo event of the same medication.
  static const String invalidUndoTarget = 'invalid_undo_target';

  /// The occurrence's schedule belongs to another medication.
  static const String invalidOccurrenceKey = 'invalid_occurrence_key';

  /// The same dose-event id was recorded with a different payload.
  static const String idempotencyConflict = 'idempotency_conflict';

  /// Stable code.
  final String code;

  /// Wire name of the invalid field (`name`, `notes`, ...), if any.
  final String? field;

  @override
  String toString() => 'DataException($code${field == null ? '' : ', $field'})';
}

/// The next last-write-wins key for a row whose key is [previousMicros].
///
/// Never behind the clock and strictly greater than the previous key, so a
/// row's keys increase even when the device clock goes backwards.
int nextConflictKey(DateTime now, int? previousMicros) {
  final micros = now.toUtc().microsecondsSinceEpoch;
  if (previousMicros == null || micros > previousMicros) {
    return micros;
  }
  return previousMicros + 1;
}

/// Microseconds since epoch to a UTC [DateTime].
DateTime microsToInstant(int micros) =>
    DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);

/// Shared plumbing of the repositories: clock, ids, device id and outbox.
class LocalWriter {
  /// Creates a writer.
  LocalWriter({
    required this.db,
    required this.syncState,
    required this.clock,
    required this.newId,
  });

  /// Database.
  final AppDatabase db;

  /// Device id source.
  final SyncStateStore syncState;

  /// Clock.
  final Clock clock;

  /// Id generator.
  final IdGenerator newId;

  /// The current instant in microseconds.
  int nowMicros() => clock().toUtc().microsecondsSinceEpoch;

  /// Runs [action] in one transaction with this device's id.
  Future<T> write<T>(Future<T> Function(String deviceId) action) async {
    final deviceId = await syncState.deviceId();
    return db.transaction(() => action(deviceId));
  }

  /// Appends a mutation to the outbox (inside the caller's transaction).
  Future<void> enqueue({
    required SyncEntity entity,
    required SyncOp op,
    required String id,
    required int clientUpdatedAt,
    JsonMap? payload,
  }) async {
    await db.into(db.outbox).insert(
          OutboxCompanion.insert(
            entityKind: entity.wire,
            op: op.wire,
            entityId: id,
            payload: Value(payload == null ? null : jsonEncode(payload)),
            clientUpdatedAt: clientUpdatedAt,
          ),
        );
  }
}
