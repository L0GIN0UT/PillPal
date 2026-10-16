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
        (row) => row.medicationId.equals(medicationId) & row.deletedAt.isNull(),
      );
    return query.watch();
  }

  /// Live schedules of [medicationId], read once.
  Future<List<ScheduleRow>> forMedication(String medicationId) {
    final query = _db.select(_db.schedules)
      ..where(
        (row) => row.medicationId.equals(medicationId) & row.deletedAt.isNull(),
      );
    return query.get();
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
  Future<String> create({
    required String medicationId,
    required Object? rule,
  }) async {
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
  Future<void> update(String id, Object? rule) async {
    final canonical = _canonical(rule);
    return _writer.write((deviceId) async {
      final current = await _live(id);
      final row = current.copyWith(
        rule: canonical,
        clientUpdatedAt:
            nextConflictKey(_writer.clock(), current.clientUpdatedAt),
        updatedByDevice: deviceId,
      );
      await _db.update(_db.schedules).replace(row.toCompanion(false));
      await _enqueueUpsert(row);
    });
  }

  /// Ends schedule [id] on [endDate] and creates a schedule of the same
  /// medication with [rule], in one transaction (ADR 0003 §1: an edit of a
  /// started schedule keeps the past). Returns the new schedule's id.
  Future<String> split(
    String id, {
    required LocalDate endDate,
    required Object? rule,
  }) async {
    final canonical = _canonical(rule);
    return _writer.write((deviceId) async {
      final current = await _live(id);
      await _endIn(current, endDate, deviceId);
      final row = ScheduleRow(
        id: _writer.newId(),
        medicationId: current.medicationId,
        rule: canonical,
        clientUpdatedAt: _writer.nowMicros(),
        updatedByDevice: deviceId,
      );
      await _db.into(_db.schedules).insert(row);
      await _enqueueUpsert(row);
      return row.id;
    });
  }

  /// Sets the last day of a live schedule (ADR 0003 §3, "finish").
  Future<void> end(String id, LocalDate endDate) {
    return _writer.write(
      (deviceId) async => _endIn(await _live(id), endDate, deviceId),
    );
  }

  /// Finishes medication [medicationId] as of [today] (ADR 0003 §3): its
  /// running schedules end yesterday, schedules that have not started are
  /// deleted, ended ones stay as they are. One transaction.
  Future<void> finishMedication(String medicationId, LocalDate today) {
    return _writer.write((deviceId) async {
      final rows = await (_db.select(_db.schedules)
            ..where(
              (row) =>
                  row.medicationId.equals(medicationId) &
                  row.deletedAt.isNull(),
            ))
          .get();
      for (final row in rows) {
        final rule = row.scheduleRule;
        final end = rule.endDate;
        if (!rule.startDate.isBefore(today)) {
          await _deleteIn(row, deviceId);
        } else if (end == null || !end.isBefore(today)) {
          await _endIn(row, today.addDays(-1), deviceId);
        }
      }
    });
  }

  /// Deletes a schedule (its dose events stay in the history).
  Future<void> delete(String id) {
    return _writer.write(
      (deviceId) async => _deleteIn(await _live(id), deviceId),
    );
  }

  Future<void> _endIn(
    ScheduleRow current,
    LocalDate endDate,
    String deviceId,
  ) async {
    final rule = jsonDecode(current.rule) as Map<String, Object?>;
    final row = current.copyWith(
      rule: _canonical({...rule, 'end_date': endDate.toString()}),
      clientUpdatedAt:
          nextConflictKey(_writer.clock(), current.clientUpdatedAt),
      updatedByDevice: deviceId,
    );
    await _db.update(_db.schedules).replace(row.toCompanion(false));
    await _enqueueUpsert(row);
  }

  Future<void> _deleteIn(ScheduleRow current, String deviceId) async {
    final key = nextConflictKey(_writer.clock(), current.clientUpdatedAt);
    await (_db.update(_db.schedules)..where((row) => row.id.equals(current.id)))
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
      id: current.id,
      clientUpdatedAt: key,
    );
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
