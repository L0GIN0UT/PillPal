import 'package:drift/drift.dart';

import '../api/sync_dto.dart';
import '../db/database.dart';

/// Hard deletes of entities in other people's scopes and the outbox cleanup
/// that goes with them (ADR 0006 §7): such scopes keep no tombstones, and a
/// pending local edit must never outlive the projection that removed its
/// entity or hid its fields. Callers run this inside a transaction.
class EntityEraser {
  /// Creates an eraser over [db].
  EntityEraser(this._db);

  final AppDatabase _db;

  /// Deletes the entity [id] and its children locally, with their outbox
  /// entries. A profile takes its whole scope with it.
  Future<void> erase(SyncEntity entity, String id) async {
    switch (entity) {
      case SyncEntity.profile:
        await _db.evictScope(id);
      case SyncEntity.medication:
        await dropPending(SyncEntity.medication, id);
        await (_db.delete(_db.doseEvents)
              ..where((row) => row.medicationId.equals(id)))
            .go();
        await (_db.delete(_db.schedules)
              ..where((row) => row.medicationId.equals(id)))
            .go();
        await (_db.delete(_db.medicationReminderSettings)
              ..where((row) => row.medicationId.equals(id)))
            .go();
        await (_db.delete(_db.medications)..where((row) => row.id.equals(id)))
            .go();
      case SyncEntity.schedule:
        await dropPending(SyncEntity.schedule, id);
        await (_db.delete(_db.schedules)..where((row) => row.id.equals(id)))
            .go();
      case SyncEntity.doseEvent:
        await dropPending(SyncEntity.doseEvent, id);
        await (_db.delete(_db.doseEvents)..where((row) => row.id.equals(id)))
            .go();
    }
  }

  /// Drops the outbox entries of the entity [id] alone, parked ones
  /// included; its children keep theirs.
  Future<void> dropOwnPending(SyncEntity entity, String id) =>
      _dropEntries(entity, (column) => column.equals(id));

  /// Drops the outbox entries of the entity [id] and of its children (a
  /// medication's schedules and dose events), parked ones included.
  Future<void> dropPending(SyncEntity entity, String id) async {
    await dropOwnPending(entity, id);
    if (entity != SyncEntity.medication) {
      return;
    }
    final schedules = _db.selectOnly(_db.schedules)
      ..addColumns([_db.schedules.id])
      ..where(_db.schedules.medicationId.equals(id));
    await _dropEntries(
      SyncEntity.schedule,
      (column) => column.isInQuery(schedules),
    );
    final events = _db.selectOnly(_db.doseEvents)
      ..addColumns([_db.doseEvents.id])
      ..where(_db.doseEvents.medicationId.equals(id));
    await _dropEntries(
      SyncEntity.doseEvent,
      (column) => column.isInQuery(events),
    );
  }

  Future<void> _dropEntries(
    SyncEntity entity,
    Expression<bool> Function(GeneratedColumn<String> entityId) matches,
  ) async {
    await (_db.delete(_db.outbox)
          ..where(
            (row) => row.entityKind.equals(entity.wire) & matches(row.entityId),
          ))
        .go();
  }
}
