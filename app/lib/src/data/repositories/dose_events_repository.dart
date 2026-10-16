import 'package:drift/drift.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../api/sync_dto.dart';
import '../db/database.dart';
import 'dose_event_queries.dart';
import 'local_writer.dart';
import '../config.dart';
import 'payloads.dart';
import 'validation.dart';

// The event kinds live in pillpal_core with the dose-state contract
// (docs/spec/dose-state.md); re-exported for the app's importers.
export 'package:pillpal_core/pillpal_core.dart' show DoseEventType;

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

  /// Events of all medications recorded after [from], oldest first (stock
  /// baselines, docs/adr/0004-stock-tracking.md).
  Stream<List<DoseEventRow>> watchAfter(DateTime from) {
    final query = _db.select(_db.doseEvents)
      ..where(
        (row) => row.at.isBiggerThanValue(from.toUtc().microsecondsSinceEpoch),
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

  /// Events the local days `[firstDay, lastDay]` need (ADR 0003 §5):
  /// events of [scheduleIds] whose occurrence key falls on those nominal
  /// dates, whenever they were recorded, plus as-needed intakes (no
  /// occurrence) recorded in `[from, to)` and their undos recorded from
  /// [from] on. Oldest first.
  Stream<List<DoseEventRow>> watchForDays({
    required Iterable<String> scheduleIds,
    required LocalDate firstDay,
    required LocalDate lastDay,
    required DateTime from,
    required DateTime to,
  }) {
    return selectDoseEventsForDays(
      _db,
      scheduleIds: scheduleIds,
      firstDay: firstDay,
      lastDay: lastDay,
      from: from,
      to: to,
    ).watch();
  }

  /// A dose event by id, or null.
  Future<DoseEventRow?> find(String id) {
    return (_db.select(_db.doseEvents)..where((row) => row.id.equals(id)))
        .getSingleOrNull();
  }

  /// Records a `taken` or `skipped` event; returns its id.
  ///
  /// Idempotent by [id] (pass one to make a retried action safe, e.g. from a
  /// notification): the same payload again is a no-op, a different one
  /// throws `idempotency_conflict`. Tombstoned medications still accept
  /// events, as on the server (history must not be lost). Snoozes go
  /// through [snooze] (they need `snooze_until`), corrections through
  /// [undo].
  Future<String> record({
    required String medicationId,
    required DoseEventType type,
    required DateTime at,
    OccurrenceRef? occurrence,
    String? note,
    String? id,
  }) async {
    if (type == DoseEventType.undo || type == DoseEventType.snoozed) {
      throw ArgumentError.value(type, 'type', 'Use undo() or snooze()');
    }
    // Without a skip condition, _append always records (or replays).
    return (await _append(
      medicationId: medicationId,
      type: type,
      at: at,
      occurrenceKey: occurrence?.key,
      targetEventId: null,
      note: note,
      id: id,
    ))!;
  }

  /// Records a `taken` or `skipped` mark for [occurrence] unless
  /// [isApplied], given the occurrence's events read in the same
  /// transaction, says the mark is already in effect (a repeated tap, a
  /// second device; ADR 0003 §6). Returns the new event's id, or null when
  /// nothing was recorded.
  Future<String?> recordMark({
    required String medicationId,
    required DoseEventType type,
    required DateTime at,
    required OccurrenceRef occurrence,
    required bool Function(List<DoseEventRow> events) isApplied,
  }) async {
    if (type != DoseEventType.taken && type != DoseEventType.skipped) {
      throw ArgumentError.value(type, 'type', 'Not a mark');
    }
    return _append(
      medicationId: medicationId,
      type: type,
      at: at,
      occurrenceKey: occurrence.key,
      targetEventId: null,
      note: null,
      id: null,
      skipIf: () async => isApplied(await _eventsOf(occurrence.key)),
    );
  }

  /// Records an `undo` of [targetEventId] unless one already exists (a
  /// repeated tap); returns the new event's id, or null when nothing was
  /// recorded.
  Future<String?> undoOnce({
    required String targetEventId,
    required DateTime at,
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
      note: null,
      id: null,
      skipIf: () async {
        final undos = await (_db.select(_db.doseEvents)
              ..where((row) => row.targetEventId.equals(targetEventId))
              ..limit(1))
            .get();
        return undos.isNotEmpty;
      },
    );
  }

  /// The events of [occurrenceKey] and the undos that cancel them, also
  /// those carrying another key or none (an older client;
  /// docs/spec/dose-state.md §2: an undo applies by its target).
  Future<List<DoseEventRow>> _eventsOf(String occurrenceKey) async {
    final own = await (_db.select(_db.doseEvents)
          ..where((row) => row.occurrenceKey.equals(occurrenceKey))
          ..orderBy([(row) => OrderingTerm.asc(row.at)]))
        .get();
    if (own.isEmpty) {
      return own;
    }
    final ids = {for (final row in own) row.id};
    final cancelling = await (_db.select(_db.doseEvents)
          ..where(
            (row) =>
                row.eventType.equals(DoseEventType.undo.wire) &
                row.targetEventId.isIn(ids),
          ))
        .get();
    return [
      ...own,
      for (final row in cancelling)
        if (!ids.contains(row.id)) row,
    ];
  }

  /// Records that [occurrence] was snoozed at [at] until [until]; returns
  /// the event's id.
  ///
  /// [until] must be after [at] and at most [SyncLimits.maxSnooze] later
  /// (as on the server), else `validation_error` on `snooze_until`.
  /// Idempotent by [id] like [record].
  Future<String> snooze({
    required String medicationId,
    required OccurrenceRef occurrence,
    required DateTime at,
    required DateTime until,
    String? note,
    String? id,
  }) async {
    final start = at.toUtc();
    final end = until.toUtc();
    if (!end.isAfter(start) || end.isAfter(start.add(SyncLimits.maxSnooze))) {
      throw const DataException(
        DataException.validationError,
        field: 'snooze_until',
      );
    }
    return (await _append(
      medicationId: medicationId,
      type: DoseEventType.snoozed,
      at: start,
      occurrenceKey: occurrence.key,
      targetEventId: null,
      note: note,
      id: id,
      snoozeUntil: end,
    ))!;
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
    return (await _append(
      medicationId: target.medicationId,
      type: DoseEventType.undo,
      at: at,
      occurrenceKey: target.occurrenceKey,
      targetEventId: targetEventId,
      note: note,
      id: id,
    ))!;
  }

  Future<String?> _append({
    required String medicationId,
    required DoseEventType type,
    required DateTime at,
    required String? occurrenceKey,
    required String? targetEventId,
    required String? note,
    required String? id,
    Future<bool> Function()? skipIf,
    DateTime? snoozeUntil,
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
      if (skipIf != null && await skipIf()) {
        return null;
      }
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
        snoozeUntil: snoozeUntil?.microsecondsSinceEpoch,
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
        a.note == b.note &&
        a.snoozeUntil == b.snoozeUntil;
  }
}
