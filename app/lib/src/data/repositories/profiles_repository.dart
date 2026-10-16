import 'package:drift/drift.dart';

import '../api/sync_dto.dart';
import '../db/database.dart';
import 'local_writer.dart';
import 'payloads.dart';

/// Profiles: the user's own (`self`, created by the server at registration)
/// and the ones they manage.
class ProfilesRepository {
  /// Creates the repository.
  ProfilesRepository(this._writer);

  final LocalWriter _writer;

  AppDatabase get _db => _writer.db;

  /// Live profiles, the `self` profile first.
  Stream<List<ProfileRow>> watchAll() {
    final query = _db.select(_db.profiles)
      ..where((row) => row.deletedAt.isNull())
      ..orderBy([
        (row) => OrderingTerm.desc(row.kind.equals('self')),
        (row) => OrderingTerm.asc(row.displayName),
      ]);
    return query.watch();
  }

  /// A profile by id (also tombstones), or null.
  Future<ProfileRow?> find(String id) {
    return (_db.select(_db.profiles)..where((row) => row.id.equals(id)))
        .getSingleOrNull();
  }

  /// Creates a managed profile; returns its id.
  Future<String> create({
    required String displayName,
    required String timezone,
  }) {
    return _writer.write((deviceId) async {
      final row = ProfileRow(
        id: _writer.newId(),
        kind: 'managed',
        displayName: displayName,
        timezone: timezone,
        clientUpdatedAt: _writer.nowMicros(),
        updatedByDevice: deviceId,
      );
      await _db.into(_db.profiles).insert(row);
      await _enqueueUpsert(row);
      return row.id;
    });
  }

  /// Renames a profile or changes its time zone.
  Future<void> update(String id, {String? displayName, String? timezone}) {
    return _writer.write((deviceId) async {
      final current = await _live(id);
      final row = current.copyWith(
        displayName: displayName ?? current.displayName,
        timezone: timezone ?? current.timezone,
        clientUpdatedAt:
            nextConflictKey(_writer.clock(), current.clientUpdatedAt),
        updatedByDevice: deviceId,
      );
      await _db.update(_db.profiles).replace(row);
      await _enqueueUpsert(row);
    });
  }

  /// Deletes a managed profile with its medications and schedules.
  Future<void> delete(String id) {
    return _writer.write((deviceId) async {
      final current = await _live(id);
      if (current.kind == 'self') {
        throw const DataException(DataException.selfProfileProtected);
      }
      final key = nextConflictKey(_writer.clock(), current.clientUpdatedAt);
      await (_db.update(_db.profiles)..where((row) => row.id.equals(id)))
          .write(
        ProfilesCompanion(
          clientUpdatedAt: Value(key),
          updatedByDevice: Value(deviceId),
          deletedAt: Value(_writer.nowMicros()),
        ),
      );
      // The server cascades too; locally the children disappear at once.
      await markProfileChildrenDeleted(_db, id, _writer.nowMicros());
      await _writer.enqueue(
        entity: SyncEntity.profile,
        op: SyncOp.delete,
        id: id,
        clientUpdatedAt: key,
      );
    });
  }

  Future<ProfileRow> _live(String id) async {
    final row = await find(id);
    if (row == null) {
      throw const DataException(DataException.notFound);
    }
    if (row.deletedAt != null) {
      throw const DataException(DataException.deleted);
    }
    return row;
  }

  Future<void> _enqueueUpsert(ProfileRow row) {
    return _writer.enqueue(
      entity: SyncEntity.profile,
      op: SyncOp.upsert,
      id: row.id,
      clientUpdatedAt: row.clientUpdatedAt,
      payload: profilePayload(row),
    );
  }
}

/// Tombstones the medications (and their schedules) of profile [profileId].
Future<void> markProfileChildrenDeleted(
  AppDatabase db,
  String profileId,
  int deletedAtMicros,
) async {
  final medications = await (db.select(db.medications)
        ..where(
          (row) => row.profileId.equals(profileId) & row.deletedAt.isNull(),
        ))
      .get();
  for (final medication in medications) {
    await (db.update(db.medications)
          ..where((row) => row.id.equals(medication.id)))
        .write(MedicationsCompanion(deletedAt: Value(deletedAtMicros)));
    await markMedicationChildrenDeleted(db, medication.id, deletedAtMicros);
  }
}

/// Tombstones the live schedules of medication [medicationId].
Future<void> markMedicationChildrenDeleted(
  AppDatabase db,
  String medicationId,
  int deletedAtMicros,
) async {
  await (db.update(db.schedules)
        ..where(
          (row) =>
              row.medicationId.equals(medicationId) & row.deletedAt.isNull(),
        ))
      .write(SchedulesCompanion(deletedAt: Value(deletedAtMicros)));
}
