import 'package:drift/drift.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../api/json.dart';
import '../api/sync_dto.dart';
import '../catalog/catalog_link.dart';
import '../catalog/manual_ingredient.dart';
import '../config.dart';
import '../db/database.dart';
import 'local_writer.dart';
import 'medication_draft.dart';
import 'payloads.dart';
import 'profiles_repository.dart';

export 'medication_draft.dart';

/// Medications of profiles.
class MedicationsRepository {
  /// Creates the repository. [contributionsEnabled] answers whether the
  /// server accepts contribution consent (`/v1/me/features`); by default it
  /// does not, so no tick is accepted.
  MedicationsRepository(
    this._writer, {
    Future<bool> Function()? contributionsEnabled,
  }) : _contributionsEnabled = contributionsEnabled ?? _never;

  static Future<bool> _never() async => false;

  final LocalWriter _writer;
  final Future<bool> Function() _contributionsEnabled;

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
    final wanted = valid.catalogLink ?? const CatalogLink.none();
    await _checkTick(wanted);
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
      final role = await _roleOf(profileId);
      final link = _resolveLink(wanted, null, role);
      final row = _row(
        id: _writer.newId(),
        profileId: profileId,
        draft: valid,
        link: link,
        ingredients: valid.manualIngredients ?? const [],
        key: _writer.nowMicros() + (link.consentVersion == null ? 0 : 1),
        deviceId: deviceId,
      );
      await _db.into(_db.medications).insert(row);
      await _enqueueUpsert(row, role: role, link: link);
      return row.id;
    });
  }

  /// Replaces the editable fields of a live medication.
  ///
  /// A changed (GTIN, product) pair resets the consent to count it; the
  /// consent survives only an unchanged pair, or a write that carries the
  /// user's fresh tick (`CatalogLink.consentVersion`). Roles without full
  /// access never consent and never send the flag (ADR 0015 §4). A tick is
  /// refused (`DataException`) unless the server allows contributions, the
  /// GTIN is shareable and the consent version is known.
  Future<void> update(String id, MedicationDraft draft) {
    final valid = draft.validated();
    return _edit(id, (_) => valid, tick: valid.catalogLink);
  }

  /// Links a package to the existing medication [id] (owner decision D4):
  /// the package, product and GTIN of [link] replace the stored ones, the
  /// composition only if there was none; name, text, schedules, stock and
  /// history stay. It is an ordinary edit, so consent is reset unless
  /// [link] carries a fresh tick; the same pair keeps its stored consent.
  Future<void> linkPackage(String id, CatalogLink link) {
    return _edit(
      id,
      (current) {
        final stored = CatalogLink.fromRow(current);
        final keeps = link.samePair(stored) && stored.shared;
        final merged = CatalogLink(
          productId: link.productId,
          packageId: link.packageId,
          compositionId: current.catalogCompositionId ?? link.compositionId,
          gtin: link.gtin,
          shared: link.shared || keeps,
          consentVersion: link.consentVersion,
        );
        return MedicationDraft.fromRow(current).withCatalogLink(merged);
      },
      tick: link,
    );
  }

  /// Sets the stock of a live medication to a freshly counted [count] (a
  /// new baseline, "Пополнить запас"); the other fields stay.
  Future<void> setStock(String id, String count) {
    return _edit(
      id,
      (current) => MedicationDraft.fromRow(current).withNewStock(count),
    );
  }

  /// Reads, merges and writes one medication inside a single transaction,
  /// so a concurrent change is never overwritten with stale data.
  Future<void> _edit(
    String id,
    MedicationDraft Function(MedicationRow current) build, {
    CatalogLink? tick,
  }) async {
    await _checkTick(tick);
    return _writer.write((deviceId) async {
      final current = await _live(id);
      final valid = build(current).validated();
      final role = await _roleOf(current.profileId);
      final wanted = valid.catalogLink ?? CatalogLink.fromRow(current);
      final stored = ManualIngredient.decode(current.manualIngredients);
      final link = _resolveLink(wanted, current, role);
      final key = nextConflictKey(_writer.clock(), current.clientUpdatedAt);
      final row = _row(
        id: id,
        profileId: current.profileId,
        draft: valid.keepStock ? valid.withStockOf(current) : valid,
        link: link,
        ingredients: valid.manualIngredients ?? stored,
        key: key + (link.consentVersion == null ? 0 : 1),
        deviceId: deviceId,
      );
      await _db.update(_db.medications).replace(row.toCompanion(false));
      await _enqueueUpsert(row, role: role, link: link);
      if (current.catalogProductId != row.catalogProductId) {
        await _db.evictUnreferencedCatalogCards();
      }
    });
  }

  /// Deletes a medication and its schedules (dose history is kept).
  Future<void> delete(String id) {
    return _writer.write((deviceId) async {
      final current = await _live(id);
      final key = nextConflictKey(_writer.clock(), current.clientUpdatedAt);
      await (_db.update(_db.medications)..where((row) => row.id.equals(id)))
          .write(
        withoutCatalogData(
          MedicationsCompanion(
            clientUpdatedAt: Value(key),
            updatedByDevice: Value(deviceId),
            deletedAt: Value(_writer.nowMicros()),
          ),
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

  /// The account's role in [profileId], or null without a scope row.
  Future<String?> _roleOf(String profileId) async {
    final scope = await (_db.select(_db.accessScopes)
          ..where((row) => row.profileId.equals(profileId)))
        .getSingleOrNull();
    return scope?.role;
  }

  /// Refuses a tick the server would refuse, before anything is written:
  /// an unknown consent version, a GTIN that is not shareable (check digit,
  /// restricted number) or contributions switched off. A refused tick must
  /// not reach the outbox, where the server would reject it.
  Future<void> _checkTick(CatalogLink? link) async {
    final version = link?.consentVersion;
    if (link == null || version == null || !link.shared) {
      return;
    }
    if (!CatalogPolicy.knownConsentVersions.contains(version)) {
      throw const DataException(
        DataException.validationError,
        field: 'gtin_link_consent_version',
      );
    }
    final gtin = link.gtin;
    if (gtin == null || link.productId == null) {
      return; // not a pair: no consent is recorded
    }
    if (!_isShareable(gtin)) {
      throw const DataException(DataException.validationError, field: 'gtin');
    }
    if (!await _contributionsEnabled()) {
      throw const DataException(
        DataException.validationError,
        field: 'gtin_link_shared',
      );
    }
  }

  bool _isShareable(String gtin) {
    try {
      final parsed = normalizeGtin(gtin);
      return parsed.classification == GtinClassification.shareable;
    } on GtinException {
      return false;
    }
  }

  /// The link to store: consent is kept only for an unchanged pair or a
  /// fresh tick, and only for full-access roles with both halves present.
  /// Without a scope row ([role] null) the stored consent is kept as it
  /// is, locally. A grant (a tick on a pair that has no consent yet) is the
  /// only link that carries a `consentVersion`.
  CatalogLink _resolveLink(
    CatalogLink wanted,
    MedicationRow? current,
    String? role,
  ) {
    final hasPair = wanted.gtin != null && wanted.productId != null;
    final stored = current != null &&
        current.gtinLinkShared &&
        wanted.samePair(CatalogLink.fromRow(current));
    final ticked = wanted.shared && wanted.consentVersion != null;
    var shared = false;
    int? version;
    if (role == null) {
      shared = stored;
    } else if (ScopeRole.hasFullAccess(role) && hasPair) {
      shared = ticked || (stored && wanted.shared);
      version = ticked && !stored ? wanted.consentVersion : null;
    }
    return CatalogLink(
      productId: wanted.productId,
      packageId: wanted.packageId,
      compositionId: wanted.compositionId,
      gtin: wanted.gtin,
      shared: shared,
      consentVersion: version,
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

  /// Queues the full state of [row].
  ///
  /// A grant of consent is a separate follow-up entry (full state, the
  /// version, key + 1) behind an entry that does not carry it: if the
  /// server refuses the grant, only that entry is parked and the create or
  /// edit stays intact. The version rides in that one entry only; later
  /// snapshots are built from the row, which does not hold it. [row]
  /// already has the key of the follow-up.
  Future<void> _enqueueUpsert(
    MedicationRow row, {
    required String? role,
    required CatalogLink link,
  }) async {
    final fullAccess = role != null && ScopeRole.hasFullAccess(role);
    final version = link.consentVersion;
    if (version == null) {
      await _enqueue(row, medicationPayload(row, fullAccess: fullAccess));
      return;
    }
    final base = row.copyWith(
      gtinLinkShared: false,
      clientUpdatedAt: row.clientUpdatedAt - 1,
    );
    await _enqueue(base, medicationPayload(base, fullAccess: true));
    await _enqueue(
      row,
      medicationPayload(row, fullAccess: true, consentVersion: version),
    );
  }

  Future<void> _enqueue(MedicationRow row, JsonMap payload) {
    return _writer.enqueue(
      entity: SyncEntity.medication,
      op: SyncOp.upsert,
      id: row.id,
      profileId: row.profileId,
      clientUpdatedAt: row.clientUpdatedAt,
      payload: payload,
    );
  }
}
