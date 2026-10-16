import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../api/sync_dto.dart';
import '../db/database.dart';
import 'local_writer.dart';
import 'payloads.dart';

/// The validated rule of a schedule row.
extension ScheduleRowRule on ScheduleRow {
  /// Parses [rule] (stored canonical, so this does not throw for synced rows).
  ScheduleRule get scheduleRule => ScheduleRule.fromJson(jsonDecode(rule));
}

/// Schedules of medications (rule v1, docs/spec/schedule.md).
class SchedulesRepository {
  /// Creates the repository.
  SchedulesRepository(this._writer);

  final LocalWriter _writer;

  AppDatabase get _db => _writer.db;

  /// Live schedules of [medicationId].
  Stream<List<ScheduleRow>> watchForMedication(String medicationId) {
    final query = _db.select(_db.schedules)
      ..where(
        (row) =>
            row.medicationId.equals(medicationId) & row.deletedAt.isNull(),
      );
    return query.watch();
  }

  /// All live schedules (for building occurrences).
  Stream<List<ScheduleRow>> watchAll() {
    final query = _db.select(_db.schedules)
      ..where((row) => row.deletedAt.isNull());
    return query.watch();
  }

  /// A schedule by id (also tombstones), or null.
  Future<ScheduleRow?> find(String id) {
    return (_db.select(_db.schedules)..where((row) => row.id.equals(id)))
        .getSingleOrNull();
  }

  /// Creates a schedule of a live medication; [rule] is decoded rule JSON.
  ///
  /// Throws [DataException] `invalid_rule` if `ScheduleRule.fromJson`
  /// rejects it. The canonical form is stored and pushed.
  Future<String> create({required String medicationId, required Object? rule}) {
    final canonical = _canonical(rule);
    return _writer.write((deviceId) async {
      final medication = await (_db.select(_db.medications)
            ..where((row) => row.id.equals(medicationId)))
          .getSingleOrNull();
      if (medication == null) {
        throw const DataException(DataException.parentNotFound);
      }
      if (medication.deletedAt != null) {
        throw const DataException(DataException.parentDeleted);
      }
      final row = ScheduleRow(
        id: _writer.newId(),
        medicationId: medicationId,
        rule: canonical,
        clientUpdatedAt: _writer.nowMicros(),
        updatedByDevice: deviceId,
      );
      await _db.into(_db.schedules).insert(row);
      await _enqueueUpsert(row);
      return row.id;
    });
  }

  /// Replaces the rule of a live schedule.
  Future<void> update(String id, Object? rule) {
    final canonical = _canonical(rule);
    return _writer.write((deviceId) async {
      final current = await _live(id);
      final row = current.copyWith(
        rule: canonical,
        clientUpdatedAt:
            nextConflictKey(_writer.clock(), current.clientUpdatedAt),
        updatedByDevice: deviceId,
      );
      await _db.update(_db.schedules).replace(row);
      await _enqueueUpsert(row);
    });
  }

  /// Deletes a schedule (its dose events stay in the history).
  Future<void> delete(String id) {
    return _writer.write((deviceId) async {
      final current = await _live(id);
      final key = nextConflictKey(_writer.clock(), current.clientUpdatedAt);
      await (_db.update(_db.schedules)..where((row) => row.id.equals(id)))
          .write(
        SchedulesCompanion(
          clientUpdatedAt: Value(key),
          updatedByDevice: Value(deviceId),
          deletedAt: Value(_writer.nowMicros()),
        ),
      );
      await _writer.enqueue(
        entity: SyncEntity.schedule,
        op: SyncOp.delete,
        id: id,
        clientUpdatedAt: key,
      );
    });
  }

  String _canonical(Object? rule) {
    try {
      return jsonEncode(ScheduleRule.fromJson(rule).toJson());
    } on RuleValidationError {
      throw const DataException(DataException.invalidRule);
    }
  }

  Future<ScheduleRow> _live(String id) async {
    final row = await find(id);
    if (row == null) {
      throw const DataException(DataException.notFound);
    }
    if (row.deletedAt != null) {
      throw const DataException(DataException.deleted);
    }
    return row;
  }

  Future<void> _enqueueUpsert(ScheduleRow row) {
    return _writer.enqueue(
      entity: SyncEntity.schedule,
      op: SyncOp.upsert,
      id: row.id,
      clientUpdatedAt: row.clientUpdatedAt,
      payload: schedulePayload(row),
    );
  }
}
