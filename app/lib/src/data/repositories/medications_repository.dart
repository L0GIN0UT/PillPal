import 'package:drift/drift.dart';

import '../api/sync_dto.dart';
import '../db/database.dart';
import 'local_writer.dart';
import 'payloads.dart';
import 'profiles_repository.dart';
import 'validation.dart';

/// Editable fields of a medication (TZ §2.1, free input).
class MedicationDraft {
  /// Creates a draft; [tzMode] `fixed` requires [fixedTz].
  const MedicationDraft({
    required this.name,
    this.form,
    this.strengthText,
    this.notes,
    this.tzMode = 'local',
    this.fixedTz,
    this.stockCount,
    this.stockUnit,
    this.lowStockDays,
    this.stockSetAt,
    this.keepStock = false,
    this.privacy = 'shared',
  });

  /// The editable fields of [row]; its stock baseline is kept.
  factory MedicationDraft.fromRow(MedicationRow row) => MedicationDraft(
        name: row.name,
        form: row.form,
        strengthText: row.strengthText,
        notes: row.notes,
        tzMode: row.tzMode,
        fixedTz: row.fixedTz,
        stockCount: row.stockCount,
        stockUnit: row.stockUnit,
        lowStockDays: row.lowStockDays,
        stockSetAt: stockBaselineOf(row),
        privacy: row.privacy,
      );

  /// Name, 1..200 characters.
  final String name;

  /// Dosage form.
  final String? form;

  /// Strength text.
  final String? strengthText;

  /// Notes.
  final String? notes;

  /// `local` or `fixed`.
  final String tzMode;

  /// IANA zone for `fixed`.
  final String? fixedTz;

  /// Decimal stock as a string with at most 3 decimals, e.g. "12.5".
  final String? stockCount;

  /// Stock unit.
  final String? stockUnit;

  /// Low-stock threshold in days (0..365).
  final int? lowStockDays;

  /// When [stockCount] was counted (the stock baseline, TZ §2.4). Null with
  /// a [stockCount] means "counted now": the repository stamps the write
  /// time. Ignored without a [stockCount].
  final DateTime? stockSetAt;

  /// Keep the stored stock count, unit and baseline on update, whatever
  /// [stockCount], [stockUnit] and [stockSetAt] say: forms that only show
  /// the stock must not overwrite a refill made meanwhile.
  final bool keepStock;

  /// This draft with the stored stock of [row] (read inside the write).
  MedicationDraft _withStockOf(MedicationRow row) => MedicationDraft(
        name: name,
        form: form,
        strengthText: strengthText,
        notes: notes,
        tzMode: tzMode,
        fixedTz: fixedTz,
        stockCount: row.stockCount,
        stockUnit: row.stockCount == null ? null : row.stockUnit,
        lowStockDays: lowStockDays,
        stockSetAt: stockBaselineOf(row),
        privacy: privacy,
      );

  /// This draft with a freshly counted stock of [count] (a new baseline,
  /// stamped when written).
  MedicationDraft withNewStock(String count) => MedicationDraft(
        name: name,
        form: form,
        strengthText: strengthText,
        notes: notes,
        tzMode: tzMode,
        fixedTz: fixedTz,
        stockCount: count,
        stockUnit: stockUnit,
        lowStockDays: lowStockDays,
        privacy: privacy,
      );

  /// `shared`, `anonymous` or `hidden`.
  final String privacy;

  /// This draft normalised as the server stores it; throws [DataException]
  /// (`validation_error`, with the field) if the server would reject it.
  MedicationDraft validated() {
    final mode = oneOf(tzMode, 'tz_mode', const {'local', 'fixed'});
    final fixed = fixedTz;
    final zone = fixed == null ? null : timezoneName(fixed, 'fixed_tz');
    if ((mode == 'fixed') != (zone != null)) {
      throw const DataException(
        DataException.validationError,
        field: 'fixed_tz',
      );
    }
    final count = validStockCount(stockCount, 'stock_count');
    return MedicationDraft(
      name: requiredText(name, 'name', max: FieldLimits.medicationName),
      form: optionalText(form, 'form', max: FieldLimits.shortText),
      strengthText: optionalText(
        strengthText,
        'strength_text',
        max: FieldLimits.shortText,
      ),
      notes: optionalText(notes, 'notes', max: FieldLimits.notes, trim: false),
      tzMode: mode,
      fixedTz: zone,
      stockCount: count,
      stockUnit: optionalText(stockUnit, 'stock_unit', max: FieldLimits.unit),
      lowStockDays: optionalRange(
        lowStockDays,
        'low_stock_days',
        0,
        FieldLimits.lowStockDays,
      ),
      stockSetAt: count == null ? null : stockSetAt?.toUtc(),
      keepStock: keepStock,
      privacy: oneOf(
        privacy,
        'privacy',
        const {'shared', 'anonymous', 'hidden'},
      ),
    );
  }
}

/// The instant [row]'s stock was counted: `stock_set_at`, or for rows
/// written before it existed the row's conflict key (the last write, which
/// set the count at the latest); null when stock is not tracked.
DateTime? stockBaselineOf(MedicationRow row) {
  if (row.stockCount == null) {
    return null;
  }
  return microsToInstant(row.stockSetAt ?? row.clientUpdatedAt);
}

/// Medications of profiles.
class MedicationsRepository {
  /// Creates the repository.
  MedicationsRepository(this._writer);

  final LocalWriter _writer;

  AppDatabase get _db => _writer.db;

  /// Live medications of [profileId], by name.
  Stream<List<MedicationRow>> watchForProfile(String profileId) {
    final query = _db.select(_db.medications)
      ..where(
        (row) => row.profileId.equals(profileId) & row.deletedAt.isNull(),
      )
      ..orderBy([(row) => OrderingTerm.asc(row.name)]);
    return query.watch();
  }

  /// A medication by id (also tombstones), or null.
  Future<MedicationRow?> find(String id) {
    return (_db.select(_db.medications)..where((row) => row.id.equals(id)))
        .getSingleOrNull();
  }

  /// Creates a medication of a live profile; returns its id.
  Future<String> create({
    required String profileId,
    required MedicationDraft draft,
  }) async {
    final valid = draft.validated();
    return _writer.write((deviceId) async {
      final profile = await (_db.select(_db.profiles)
            ..where((row) => row.id.equals(profileId)))
          .getSingleOrNull();
      if (profile == null) {
        throw const DataException(DataException.parentNotFound);
      }
      if (profile.deletedAt != null) {
        throw const DataException(DataException.parentDeleted);
      }
      final row = _row(
        id: _writer.newId(),
        profileId: profileId,
        draft: valid,
        key: _writer.nowMicros(),
        deviceId: deviceId,
      );
      await _db.into(_db.medications).insert(row);
      await _enqueueUpsert(row);
      return row.id;
    });
  }

  /// Replaces the editable fields of a live medication.
  Future<void> update(String id, MedicationDraft draft) async {
    final valid = draft.validated();
    return _writer.write((deviceId) async {
      final current = await _live(id);
      final row = _row(
        id: id,
        profileId: current.profileId,
        draft: valid.keepStock ? valid._withStockOf(current) : valid,
        key: nextConflictKey(_writer.clock(), current.clientUpdatedAt),
        deviceId: deviceId,
      );
      await _db.update(_db.medications).replace(row.toCompanion(false));
      await _enqueueUpsert(row);
    });
  }

  /// Sets the stock of a live medication to a freshly counted [count] (a
  /// new baseline, "Пополнить запас"); the other fields stay.
  Future<void> setStock(String id, String count) async {
    final current = await _live(id);
    await update(id, MedicationDraft.fromRow(current).withNewStock(count));
  }

  /// Deletes a medication and its schedules (dose history is kept).
  Future<void> delete(String id) {
    return _writer.write((deviceId) async {
      final current = await _live(id);
      final key = nextConflictKey(_writer.clock(), current.clientUpdatedAt);
      await (_db.update(_db.medications)..where((row) => row.id.equals(id)))
          .write(
        MedicationsCompanion(
          clientUpdatedAt: Value(key),
          updatedByDevice: Value(deviceId),
          deletedAt: Value(_writer.nowMicros()),
        ),
      );
      await markMedicationChildrenDeleted(_db, id, _writer.nowMicros());
      await _writer.enqueue(
        entity: SyncEntity.medication,
        op: SyncOp.delete,
        id: id,
        clientUpdatedAt: key,
      );
    });
  }

  Future<MedicationRow> _live(String id) async {
    final row = await find(id);
    if (row == null) {
      throw const DataException(DataException.notFound);
    }
    if (row.deletedAt != null) {
      throw const DataException(DataException.deleted);
    }
    return row;
  }

  MedicationRow _row({
    required String id,
    required String profileId,
    required MedicationDraft draft,
    required int key,
    required String deviceId,
  }) {
    return MedicationRow(
      id: id,
      profileId: profileId,
      name: draft.name,
      form: draft.form,
      strengthText: draft.strengthText,
      notes: draft.notes,
      tzMode: draft.tzMode,
      fixedTz: draft.fixedTz,
      stockCount: draft.stockCount,
      stockUnit: draft.stockUnit,
      lowStockDays: draft.lowStockDays,
      stockSetAt: draft.stockCount == null
          ? null
          : (draft.stockSetAt?.microsecondsSinceEpoch ?? _writer.nowMicros()),
      privacy: draft.privacy,
      clientUpdatedAt: key,
      updatedByDevice: deviceId,
    );
  }

  Future<void> _enqueueUpsert(MedicationRow row) {
    return _writer.enqueue(
      entity: SyncEntity.medication,
      op: SyncOp.upsert,
      id: row.id,
      clientUpdatedAt: row.clientUpdatedAt,
      payload: medicationPayload(row),
    );
  }
}
