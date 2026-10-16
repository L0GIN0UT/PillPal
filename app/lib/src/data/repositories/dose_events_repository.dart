import 'package:drift/drift.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../api/sync_dto.dart';
import '../db/database.dart';
import 'local_writer.dart';
import '../config.dart';
import 'payloads.dart';
import 'validation.dart';

/// Dose event kinds (TZ §2.4).
enum DoseEventType {
  /// The dose was taken.
  taken('taken'),

  /// The dose was deliberately skipped.
  skipped('skipped'),

  /// The reminder was postponed.
  snoozed('snoozed'),

  /// Cancels an earlier event (`targetEventId`).
  undo('undo');

  const DoseEventType(this.wire);

  /// Wire name.
  final String wire;
}

/// A scheduled occurrence, identified by the engine's occurrence key.
class OccurrenceRef {
  /// Creates a reference to the occurrence of [scheduleId] on [localDate] at
  /// [localTime] (`HH:MM`), all nominal (never DST-shifted).
  const OccurrenceRef({
    required this.scheduleId,
    required this.localDate,
    required this.localTime,
  });

  /// The reference of an [occurrence] expanded from schedule [scheduleId].
  factory OccurrenceRef.fromOccurrence(
    String scheduleId,
    Occurrence occurrence,
  ) =>
      OccurrenceRef(
        scheduleId: scheduleId,
        localDate: occurrence.localDate,
        localTime: occurrence.localTime,
      );

  /// Schedule id.
  final String scheduleId;

  /// Nominal local date.
  final LocalDate localDate;

  /// Nominal local time `HH:MM`.
  final String localTime;

  /// `{scheduleId}/{YYYY-MM-DD}T{HH:MM}`, built by `pillpal_core`.
  String get key => occurrenceKey(scheduleId, localDate, localTime);
}

/// Append-only dose events: corrections are `undo` events, never edits.
class DoseEventsRepository {
  /// Creates the repository.
  DoseEventsRepository(this._writer);

  final LocalWriter _writer;

  AppDatabase get _db => _writer.db;

  /// Events of [medicationId] in `[from, to)`, oldest first.
  Stream<List<DoseEventRow>> watchForMedication(
    String medicationId, {
    required DateTime from,
    required DateTime to,
  }) {
    final query = _db.select(_db.doseEvents)
      ..where(
        (row) =>
            row.medicationId.equals(medicationId) &
            row.at.isBiggerOrEqualValue(from.toUtc().microsecondsSinceEpoch) &
            row.at.isSmallerThanValue(to.toUtc().microsecondsSinceEpoch),
      )
      ..orderBy([(row) => OrderingTerm.asc(row.at)]);
    return query.watch();
  }

  /// Events of all medications in `[from, to)`, oldest first.
  Stream<List<DoseEventRow>> watchBetween(DateTime from, DateTime to) {
    final query = _db.select(_db.doseEvents)
      ..where(
        (row) =>
            row.at.isBiggerOrEqualValue(from.toUtc().microsecondsSinceEpoch) &
            row.at.isSmallerThanValue(to.toUtc().microsecondsSinceEpoch),
      )
      ..orderBy([(row) => OrderingTerm.asc(row.at)]);
    return query.watch();
  }

  /// A dose event by id, or null.
  Future<DoseEventRow?> find(String id) {
    return (_db.select(_db.doseEvents)..where((row) => row.id.equals(id)))
        .getSingleOrNull();
  }

  /// Records a `taken`, `skipped` or `snoozed` event; returns its id.
  ///
  /// Idempotent by [id] (pass one to make a retried action safe, e.g. from a
  /// notification): the same payload again is a no-op, a different one
  /// throws `idempotency_conflict`. Tombstoned medications still accept
  /// events, as on the server (history must not be lost).
  Future<String> record({
    required String medicationId,
    required DoseEventType type,
    required DateTime at,
    OccurrenceRef? occurrence,
    String? note,
    String? id,
  }) async {
    if (type == DoseEventType.undo) {
      throw ArgumentError.value(type, 'type', 'Use undo()');
    }
    return _append(
      medicationId: medicationId,
      type: type,
      at: at,
      occurrenceKey: occurrence?.key,
      targetEventId: null,
      note: note,
      id: id,
    );
  }

  /// Records an `undo` of [targetEventId]; returns the new event's id.
  Future<String> undo({
    required String targetEventId,
    required DateTime at,
    String? note,
    String? id,
  }) async {
    final target = await find(targetEventId);
    if (target == null || target.eventType == DoseEventType.undo.wire) {
      throw const DataException(DataException.invalidUndoTarget);
    }
    return _append(
      medicationId: target.medicationId,
      type: DoseEventType.undo,
      at: at,
      occurrenceKey: target.occurrenceKey,
      targetEventId: targetEventId,
      note: note,
      id: id,
    );
  }

  Future<String> _append({
    required String medicationId,
    required DoseEventType type,
    required DateTime at,
    required String? occurrenceKey,
    required String? targetEventId,
    required String? note,
    required String? id,
  }) async {
    // The server bounds `at` by its own clock (corrected device clock here).
    final instant = notFarFuture(
      at,
      _writer.clock(),
      SyncLimits.maxFutureSkew,
      'at',
    );
    final text = optionalText(
      note,
      'note',
      max: FieldLimits.eventNote,
      trim: false,
    );
    return _writer.write((deviceId) async {
      final medication = await (_db.select(_db.medications)
            ..where((row) => row.id.equals(medicationId)))
          .getSingleOrNull();
      if (medication == null) {
        throw const DataException(DataException.parentNotFound);
      }
      await _checkOccurrence(occurrenceKey, medicationId);
      final row = DoseEventRow(
        id: id ?? _writer.newId(),
        profileId: medication.profileId,
        medicationId: medicationId,
        eventType: type.wire,
        at: instant.microsecondsSinceEpoch,
        occurrenceKey: occurrenceKey,
        targetEventId: targetEventId,
        note: text,
        deviceId: deviceId,
      );
      final existing = await find(row.id);
      if (existing != null) {
        if (_samePayload(existing, row)) {
          return row.id; // replay: already recorded and queued
        }
        throw const DataException(DataException.idempotencyConflict);
      }
      await _db.into(_db.doseEvents).insert(row);
      await _writer.enqueue(
        entity: SyncEntity.doseEvent,
        op: SyncOp.upsert,
        id: row.id,
        clientUpdatedAt: _writer.nowMicros(),
        payload: doseEventPayload(row),
      );
      return row.id;
    });
  }

  /// A known schedule in [key] must belong to [medicationId] (as on the server).
  Future<void> _checkOccurrence(String? key, String medicationId) async {
    if (key == null) {
      return;
    }
    final scheduleId = key.split('/').first;
    final schedule = await (_db.select(_db.schedules)
          ..where((row) => row.id.equals(scheduleId)))
        .getSingleOrNull();
    if (schedule != null && schedule.medicationId != medicationId) {
      throw const DataException(DataException.invalidOccurrenceKey);
    }
  }

  bool _samePayload(DoseEventRow a, DoseEventRow b) {
    return a.medicationId == b.medicationId &&
        a.eventType == b.eventType &&
        a.at == b.at &&
        a.occurrenceKey == b.occurrenceKey &&
        a.targetEventId == b.targetEventId &&
        a.note == b.note;
  }
}
