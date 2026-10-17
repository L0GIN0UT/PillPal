import 'package:drift/drift.dart';

import '../api/json.dart';
import '../api/sync_dto.dart';
import '../db/database.dart';
import '../repositories/profiles_repository.dart';
import 'entity_eraser.dart';
import 'server_rows.dart';

/// Applies server state (pulled changes, `current` of push results) locally.
///
/// Rules of the account's own scopes (backend/README.md, "Sync protocol"):
/// * a tombstone always wins: the row (and its local children) is marked
///   deleted, even over pending local edits - deletes are final;
/// * an upsert is skipped while the entity still has a pending (not parked)
///   outbox mutation: that newer local write will be pushed and the server
///   answers with the winner; tombstoned rows are never resurrected;
/// * dose events are immutable: insert if missing.
///
/// Rules of other people's scopes (ADR 0006 §7), selected by the scope's
/// `role` (anything but `owner`):
/// * deletes are hard deletes and no tombstone is ever kept;
/// * dose events are overwritten (the projection strips notes);
/// * for projected roles (`editor`, `viewer`) a redacted row (or an
///   `anonymous` one, which is reduced to the redacted form here), or a
///   medication whose `privacy` changed, replaces the entity whatever is
///   pending and drops the pending entries of the entity and its children,
///   so that a pending edit cannot keep full names on the device after a
///   narrowing; a `hidden` medication is erased; dose events lose `note` and
///   `device_id`;
/// * an explicit override (`current` of a refused push) replaces the entity
///   and drops only the entity's own entries.
///
/// Callers run this inside a transaction.
class ServerStateApplier {
  /// Creates an applier over [db].
  ServerStateApplier(this._db) : _eraser = EntityEraser(_db);

  final AppDatabase _db;
  final EntityEraser _eraser;

  /// Deletes [entity] [id] and its children locally, with their outbox
  /// entries, keeping no tombstone (the account's view of it ended).
  Future<void> evict(SyncEntity entity, String id) async {
    await _eraser.erase(entity, id);
  }

  /// Applies [state] of entity [id] from a scope where the account has
  /// [role]. With [overridePending] the state replaces the entity even over
  /// pending local mutations of that entity, which are dropped (`current` of
  /// a push the server refused for access reasons).
  Future<void> apply(
    SyncEntity entity,
    String id,
    EntityState state, {
    String role = ScopeRole.owner,
    bool overridePending = false,
  }) async {
    if (ScopeRole.isForeign(role)) {
      await _applyForeign(entity, id, state, role, overridePending);
      return;
    }
    if (entity == SyncEntity.doseEvent) {
      if (state.isDeleted) {
        await _markDeleted(entity, id, state);
      } else {
        await _insertDoseEvent(id, _data(state));
      }
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
    await _upsert(entity, id, _data(state), RowKey.of(state));
  }

  Future<void> _applyForeign(
    SyncEntity entity,
    String id,
    EntityState state,
    String role,
    bool overridePending,
  ) async {
    if (state.isDeleted) {
      await _eraser.erase(entity, id);
      return;
    }
    final projected = ScopeRole.isProjected(role);
    var data = _data(state);
    if (entity == SyncEntity.doseEvent) {
      // A relative never keeps notes or device ids, whatever was sent.
      final row = doseEventRow(id, data);
      final stored = projected
          ? row.copyWith(note: const Value(null), deviceId: const Value(null))
          : row;
      await _db
          .into(_db.doseEvents)
          .insertOnConflictUpdate(stored.toCompanion(false));
      return;
    }
    if (projected) {
      // The server projects; the client re-checks by `privacy`, not by the
      // `redacted` flag alone, so a server slip cannot leak into the store.
      if (entity == SyncEntity.medication && data['privacy'] == 'hidden') {
        await _eraser.erase(entity, id);
        return;
      }
      data = await _screened(entity, data);
    }
    final narrowed = projected &&
        (isRedacted(data) || await _privacyChanged(entity, id, data));
    if (narrowed) {
      await _eraser.dropPending(entity, id);
    } else if (overridePending) {
      await _eraser.dropOwnPending(entity, id);
    } else if (await hasPendingMutation(entity, id)) {
      return;
    }
    await _upsert(entity, id, data, RowKey.of(state, lenient: true));
  }

  /// [data] reduced to what a projected role may hold: an `anonymous`
  /// medication loses everything but the redacted fields, and so does the
  /// rule of its schedules (doses).
  Future<JsonMap> _screened(SyncEntity entity, JsonMap data) async {
    switch (entity) {
      case SyncEntity.medication:
        return data['privacy'] == 'anonymous' && !isRedacted(data)
            ? redactedMedicationData(data)
            : data;
      case SyncEntity.schedule:
        final parent = await (_db.select(_db.medications)
              ..where((row) => row.id.equals('${data['medication_id']}')))
            .getSingleOrNull();
        final hidesDoses = parent != null &&
            (parent.redacted || parent.privacy == 'anonymous');
        return hidesDoses && !isRedacted(data)
            ? redactedScheduleData(data)
            : data;
      case SyncEntity.profile:
      case SyncEntity.doseEvent:
        return data;
    }
  }

  /// Whether [data] changes the privacy level of the local medication [id].
  Future<bool> _privacyChanged(
    SyncEntity entity,
    String id,
    JsonMap data,
  ) async {
    if (entity != SyncEntity.medication) {
      return false;
    }
    final row = await (_db.select(_db.medications)
          ..where((r) => r.id.equals(id)))
        .getSingleOrNull();
    return row != null && row.privacy != data['privacy'];
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
    await _upsert(entity, id, data, RowKey(keyMicros, device));
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
    RowKey key,
  ) async {
    switch (entity) {
      case SyncEntity.profile:
        await _db
            .into(_db.profiles)
            .insertOnConflictUpdate(profileCompanion(id, data, key));
      case SyncEntity.medication:
        final row = medicationRow(id, data, key);
        await _db
            .into(_db.medications)
            .insertOnConflictUpdate(row.toCompanion(false));
      case SyncEntity.schedule:
        final row = scheduleRow(id, data, key);
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

  Future<void> _insertDoseEvent(String id, JsonMap data) async {
    final row = doseEventRow(id, data);
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
