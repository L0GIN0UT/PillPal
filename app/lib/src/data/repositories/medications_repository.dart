import 'package:drift/drift.dart';

import '../api/sync_dto.dart';
import '../catalog/catalog_link.dart';
import '../catalog/manual_ingredient.dart';
import '../db/database.dart';
import 'local_writer.dart';
import 'medication_draft.dart';
import 'payloads.dart';
import 'profiles_repository.dart';

export 'medication_draft.dart';

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

  /// Updates of the live medication [id]; null once it is deleted or while
  /// it is unknown.
  Stream<MedicationRow?> watchById(String id) {
    return (_db.select(_db.medications)
          ..where((row) => row.id.equals(id) & row.deletedAt.isNull()))
        .watchSingleOrNull();
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
      final fullAccess = await _hasFullAccess(profileId);
      final wanted = valid.catalogLink ?? const CatalogLink.none();
      final link = _resolveLink(wanted, null, fullAccess);
      final row = _row(
        id: _writer.newId(),
        profileId: profileId,
        draft: valid,
        link: link,
        ingredients: valid.manualIngredients ?? const [],
        key: _writer.nowMicros(),
        deviceId: deviceId,
      );
      await _db.into(_db.medications).insert(row);
      await _enqueueUpsert(row, fullAccess: fullAccess, link: link);
      return row.id;
    });
  }

  /// Replaces the editable fields of a live medication.
  ///
  /// A changed (GTIN, product) pair resets the consent to count it; the
  /// consent survives only an unchanged pair, or a write that carries the
  /// user's fresh tick (`CatalogLink.consentVersion`). Roles without full
  /// access never consent and never send the flag (ADR 0015 §4).
  Future<void> update(String id, MedicationDraft draft) async {
    final valid = draft.validated();
    return _writer.write((deviceId) async {
      final current = await _live(id);
      final fullAccess = await _hasFullAccess(current.profileId);
      final wanted = valid.catalogLink ?? CatalogLink.fromRow(current);
      final stored = ManualIngredient.decode(current.manualIngredients);
      final link = _resolveLink(wanted, current, fullAccess);
      final row = _row(
        id: id,
        profileId: current.profileId,
        draft: valid.keepStock ? valid.withStockOf(current) : valid,
        link: link,
        ingredients: valid.manualIngredients ?? stored,
        key: nextConflictKey(_writer.clock(), current.clientUpdatedAt),
        deviceId: deviceId,
      );
      await _db.update(_db.medications).replace(row.toCompanion(false));
      await _enqueueUpsert(row, fullAccess: fullAccess, link: link);
      if (current.catalogProductId != row.catalogProductId) {
        await _db.evictUnreferencedCatalogCards();
      }
    });
  }

  /// Links a package to the existing medication [id] (owner decision D4):
  /// the package, product and GTIN of [link] replace the stored ones, the
  /// composition only if there was none; name, text, schedules, stock and
  /// history stay. It is an ordinary edit, so consent is reset unless
  /// [link] carries a fresh tick.
  Future<void> linkPackage(String id, CatalogLink link) async {
    final current = await _live(id);
    final composition = current.catalogCompositionId ?? link.compositionId;
    final merged = link.withComposition(composition);
    final draft = MedicationDraft.fromRow(current).withCatalogLink(merged);
    await update(id, draft);
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
      await _db.evictUnreferencedCatalogCards();
      await _writer.enqueue(
        entity: SyncEntity.medication,
        op: SyncOp.delete,
        id: id,
        profileId: current.profileId,
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

  /// Whether the account owns the profile or co-guards it. Without a scope
  /// row the role is unknown and the consent flag is not sent.
  Future<bool> _hasFullAccess(String profileId) async {
    final scope = await (_db.select(_db.accessScopes)
          ..where((row) => row.profileId.equals(profileId)))
        .getSingleOrNull();
    return scope != null && ScopeRole.hasFullAccess(scope.role);
  }

  /// The link to store: consent is kept only for an unchanged pair or a
  /// fresh tick, and only for full-access roles with both halves present.
  CatalogLink _resolveLink(
    CatalogLink wanted,
    MedicationRow? current,
    bool fullAccess,
  ) {
    final hasPair = wanted.gtin != null && wanted.productId != null;
    final ticked = wanted.shared && wanted.consentVersion != null;
    final kept = wanted.shared &&
        current != null &&
        current.gtinLinkShared &&
        wanted.samePair(CatalogLink.fromRow(current));
    final shared = fullAccess && hasPair && (ticked || kept);
    return CatalogLink(
      productId: wanted.productId,
      packageId: wanted.packageId,
      compositionId: wanted.compositionId,
      gtin: wanted.gtin,
      shared: shared,
      consentVersion: shared && ticked ? wanted.consentVersion : null,
    );
  }

  MedicationRow _row({
    required String id,
    required String profileId,
    required MedicationDraft draft,
    required CatalogLink link,
    required List<ManualIngredient> ingredients,
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
      redacted: false,
      catalogProductId: link.productId,
      catalogPackageId: link.packageId,
      catalogCompositionId: link.compositionId,
      gtin: link.gtin,
      manualIngredients: ManualIngredient.encode(ingredients),
      gtinLinkShared: link.shared,
      clientUpdatedAt: key,
      updatedByDevice: deviceId,
    );
  }

  /// Queues the full state. The consent version rides in this one mutation
  /// only: later snapshots are built from the row, which does not hold it.
  Future<void> _enqueueUpsert(
    MedicationRow row, {
    required bool fullAccess,
    required CatalogLink link,
  }) {
    return _writer.enqueue(
      entity: SyncEntity.medication,
      op: SyncOp.upsert,
      id: row.id,
      profileId: row.profileId,
      clientUpdatedAt: row.clientUpdatedAt,
      payload: medicationPayload(
        row,
        fullAccess: fullAccess,
        consentVersion: link.consentVersion,
      ),
    );
  }
}
