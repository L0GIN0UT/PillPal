import 'dart:convert';

import 'package:drift/drift.dart';

import '../api/json.dart';
import '../api/sync_dto.dart';
import '../db/database.dart';
import '../repositories/profiles_repository.dart';

/// Applies server state (pulled changes, `current` of push results) locally.
///
/// Rules (backend/README.md, "Sync protocol"):
/// * a tombstone always wins: the row (and its local children) is marked
///   deleted, even over pending local edits - deletes are final;
/// * an upsert is skipped while the entity still has a pending (not parked)
///   outbox mutation: that newer local write will be pushed and the server
///   answers with the winner; tombstoned rows are never resurrected;
/// * dose events are immutable: insert if missing.
///
/// Callers run this inside a transaction.
class ServerStateApplier {
  /// Creates an applier over [db].
  ServerStateApplier(this._db);

  final AppDatabase _db;

  /// Keys read from `ProfileOut`.
  static const Set<String> profileKeys = {'kind', 'display_name', 'timezone'};

  /// Keys read from `MedicationOut`.
  static const Set<String> medicationKeys = {
    'profile_id',
    'name',
    'form',
    'strength_text',
    'notes',
    'tz_mode',
    'fixed_tz',
    'stock_count',
    'stock_unit',
    'low_stock_days',
    'stock_set_at',
    'privacy',
  };

  /// Keys read from `ScheduleOut`.
  static const Set<String> scheduleKeys = {'medication_id', 'rule'};

  /// Keys read from `DoseEventOut`.
  static const Set<String> doseEventKeys = {
    'profile_id',
    'medication_id',
    'type',
    'at',
    'occurrence_key',
    'target_event_id',
    'note',
    'recorded_at',
    'device_id',
    'snooze_until',
  };

  /// Applies [state] of entity [id].
  Future<void> apply(SyncEntity entity, String id, EntityState state) async {
    if (entity == SyncEntity.doseEvent) {
      await _insertDoseEvent(id, _data(state));
      return;
    }
    if (state.isDeleted) {
      await _markDeleted(entity, id, state);
      return;
    }
    if (await hasPendingMutation(entity, id) ||
        await _isTombstone(entity, id)) {
      return;
    }
    await _upsert(entity, id, _data(state), _Key.of(state));
  }

  /// Replaces the local entity with [data] (`*Out` from a GET) and makes it
  /// live again, unless a pending mutation will still be pushed for it.
  ///
  /// The REST representation has no conflict key, so the row keeps
  /// [keyMicros]/[device] (the local key of the rejected write); the next
  /// pulled change of the entity brings the server's exact key.
  Future<void> restore(
    SyncEntity entity,
    String id,
    JsonMap data, {
    required int keyMicros,
    required String device,
  }) async {
    if (entity == SyncEntity.doseEvent) {
      await (_db.delete(_db.doseEvents)..where((row) => row.id.equals(id)))
          .go();
      await _insertDoseEvent(id, data);
      return;
    }
    if (await hasPendingMutation(entity, id)) {
      return;
    }
    await _upsert(entity, id, data, _Key(keyMicros, device));
  }

  /// Whether the local parent of [entity] [id] is a tombstone.
  Future<bool> isParentDeleted(SyncEntity entity, String id) async {
    final (SyncEntity, Future<String?>)? lookup = switch (entity) {
      SyncEntity.profile => null,
      SyncEntity.medication => (
          SyncEntity.profile,
          (_db.select(_db.medications)..where((row) => row.id.equals(id)))
              .map((row) => row.profileId)
              .getSingleOrNull(),
        ),
      SyncEntity.schedule => (
          SyncEntity.medication,
          (_db.select(_db.schedules)..where((row) => row.id.equals(id)))
              .map((row) => row.medicationId)
              .getSingleOrNull(),
        ),
      SyncEntity.doseEvent => (
          SyncEntity.medication,
          (_db.select(_db.doseEvents)..where((row) => row.id.equals(id)))
              .map((row) => row.medicationId)
              .getSingleOrNull(),
        ),
    };
    if (lookup == null) {
      return false;
    }
    final parentId = await lookup.$2;
    return parentId != null && await _isTombstone(lookup.$1, parentId);
  }

  /// Writes every column (including nulls: a cleared field must clear).
  Future<void> _upsert(
    SyncEntity entity,
    String id,
    JsonMap data,
    _Key key,
  ) async {
    switch (entity) {
      case SyncEntity.profile:
        final row = _profile(id, JsonReader(data, profileKeys), key);
        await _db
            .into(_db.profiles)
            .insertOnConflictUpdate(row.toCompanion(false));
      case SyncEntity.medication:
        final row = _medication(id, JsonReader(data, medicationKeys), key);
        await _db
            .into(_db.medications)
            .insertOnConflictUpdate(row.toCompanion(false));
      case SyncEntity.schedule:
        final reader = JsonReader(data, scheduleKeys);
        final row = ScheduleRow(
          id: id,
          medicationId: reader.string('medication_id'),
          rule: jsonEncode(reader.object('rule')),
          clientUpdatedAt: key.micros,
          updatedByDevice: key.device,
        );
        await _db
            .into(_db.schedules)
            .insertOnConflictUpdate(row.toCompanion(false));
      case SyncEntity.doseEvent:
        await _insertDoseEvent(id, data);
    }
  }

  /// Whether [id] has an outbox mutation that will still be pushed.
  Future<bool> hasPendingMutation(SyncEntity entity, String id) async {
    final rows = await (_db.select(_db.outbox)
          ..where(
            (row) =>
                row.entityKind.equals(entity.wire) &
                row.entityId.equals(id) &
                row.parked.equals(false),
          )
          ..limit(1))
        .get();
    return rows.isNotEmpty;
  }

  /// Marks [id] deleted locally (no outbox entry: the server already knows).
  Future<void> markDeleted(SyncEntity entity, String id, int deletedAtMicros) =>
      _markDeleted(
        entity,
        id,
        EntityState(
          op: SyncOp.delete,
          data: null,
          clientUpdatedAt: null,
          updatedByDevice: null,
          deletedAt:
              DateTime.fromMicrosecondsSinceEpoch(deletedAtMicros, isUtc: true),
        ),
      );

  Future<void> _markDeleted(
    SyncEntity entity,
    String id,
    EntityState state,
  ) async {
    // Only "is deleted" matters locally; tombstones always carry deleted_at.
    final deletedAt =
        (state.deletedAt ?? state.clientUpdatedAt)?.microsecondsSinceEpoch ?? 0;
    final key = state.clientUpdatedAt?.microsecondsSinceEpoch;
    final device = state.updatedByDevice;
    switch (entity) {
      case SyncEntity.profile:
        await (_db.update(_db.profiles)..where((row) => row.id.equals(id)))
            .write(
          ProfilesCompanion(
            deletedAt: Value(deletedAt),
            clientUpdatedAt: key == null ? const Value.absent() : Value(key),
            updatedByDevice:
                device == null ? const Value.absent() : Value(device),
          ),
        );
        await markProfileChildrenDeleted(_db, id, deletedAt);
      case SyncEntity.medication:
        await (_db.update(_db.medications)..where((row) => row.id.equals(id)))
            .write(
          MedicationsCompanion(
            deletedAt: Value(deletedAt),
            clientUpdatedAt: key == null ? const Value.absent() : Value(key),
            updatedByDevice:
                device == null ? const Value.absent() : Value(device),
          ),
        );
        await markMedicationChildrenDeleted(_db, id, deletedAt);
      case SyncEntity.schedule:
        await (_db.update(_db.schedules)..where((row) => row.id.equals(id)))
            .write(
          SchedulesCompanion(
            deletedAt: Value(deletedAt),
            clientUpdatedAt: key == null ? const Value.absent() : Value(key),
            updatedByDevice:
                device == null ? const Value.absent() : Value(device),
          ),
        );
      case SyncEntity.doseEvent:
        // Append-only: the server never deletes dose events (except account
        // erasure, which never reaches a pull); drop a local orphan.
        await (_db.delete(_db.doseEvents)..where((row) => row.id.equals(id)))
            .go();
    }
  }

  Future<bool> _isTombstone(SyncEntity entity, String id) async {
    final Future<int?> deletedAt = switch (entity) {
      SyncEntity.profile => (_db.select(_db.profiles)
            ..where((row) => row.id.equals(id)))
          .map((row) => row.deletedAt)
          .getSingleOrNull(),
      SyncEntity.medication => (_db.select(_db.medications)
            ..where((row) => row.id.equals(id)))
          .map((row) => row.deletedAt)
          .getSingleOrNull(),
      SyncEntity.schedule => (_db.select(_db.schedules)
            ..where((row) => row.id.equals(id)))
          .map((row) => row.deletedAt)
          .getSingleOrNull(),
      SyncEntity.doseEvent => Future<int?>.value(),
    };
    return await deletedAt != null;
  }

  JsonMap _data(EntityState state) {
    final data = state.data;
    if (data == null) {
      throw const FormatException('Upsert without data');
    }
    return data;
  }

  ProfileRow _profile(String id, JsonReader reader, _Key key) => ProfileRow(
        id: id,
        kind: reader.string('kind'),
        displayName: reader.string('display_name'),
        timezone: reader.string('timezone'),
        clientUpdatedAt: key.micros,
        updatedByDevice: key.device,
      );

  MedicationRow _medication(String id, JsonReader reader, _Key key) =>
      MedicationRow(
        id: id,
        profileId: reader.string('profile_id'),
        name: reader.string('name'),
        form: reader.stringOrNull('form'),
        strengthText: reader.stringOrNull('strength_text'),
        notes: reader.stringOrNull('notes'),
        tzMode: reader.string('tz_mode'),
        fixedTz: reader.stringOrNull('fixed_tz'),
        stockCount: reader.stringOrNull('stock_count'),
        stockUnit: reader.stringOrNull('stock_unit'),
        lowStockDays: reader.integerOrNull('low_stock_days'),
        stockSetAt: reader.instantOrNull('stock_set_at')?.microsecondsSinceEpoch,
        privacy: reader.string('privacy'),
        clientUpdatedAt: key.micros,
        updatedByDevice: key.device,
      );

  Future<void> _insertDoseEvent(String id, JsonMap data) async {
    final reader = JsonReader(data, doseEventKeys);
    final row = DoseEventRow(
      id: id,
      profileId: reader.string('profile_id'),
      medicationId: reader.string('medication_id'),
      eventType: reader.string('type'),
      at: reader.instant('at').microsecondsSinceEpoch,
      occurrenceKey: reader.stringOrNull('occurrence_key'),
      targetEventId: reader.stringOrNull('target_event_id'),
      note: reader.stringOrNull('note'),
      recordedAt: reader.instantOrNull('recorded_at')?.microsecondsSinceEpoch,
      deviceId: reader.stringOrNull('device_id'),
      snoozeUntil: reader.instantOrNull('snooze_until')?.microsecondsSinceEpoch,
    );
    final existing = await (_db.select(_db.doseEvents)
          ..where((r) => r.id.equals(id)))
        .getSingleOrNull();
    if (existing == null) {
      await _db.into(_db.doseEvents).insert(row);
    } else if (existing.recordedAt == null) {
      // Our own event came back: keep it, learn the server receipt time.
      await (_db.update(_db.doseEvents)..where((r) => r.id.equals(id))).write(
        DoseEventsCompanion(
          recordedAt: Value(row.recordedAt),
          profileId: Value(row.profileId),
        ),
      );
    }
  }
}

/// The conflict key of a live mutable entity's state.
class _Key {
  const _Key(this.micros, this.device);

  factory _Key.of(EntityState state) {
    final at = state.clientUpdatedAt;
    final device = state.updatedByDevice;
    if (at == null || device == null) {
      throw const FormatException('Mutable entity state without its key');
    }
    return _Key(at.microsecondsSinceEpoch, device);
  }

  final int micros;
  final String device;
}
