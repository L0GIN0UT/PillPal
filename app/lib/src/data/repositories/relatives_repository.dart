import 'package:drift/drift.dart';

import '../api/relatives_dto.dart';
import '../db/database.dart';
import '../db/sync_state_store.dart';

/// Direction of a stored link (`relative_links.direction`).
abstract final class LinkDirection {
  /// A grant on one of the account's own profiles: someone sees me.
  static const String outgoing = 'outgoing';

  /// A grant of the account on someone else's profile: I see them.
  static const String incoming = 'incoming';
}

/// The last `GET /v1/grants` answer, kept in the local database so the
/// Family tab works offline, the account's private notes about relatives
/// (docs/adr/0020 §4) and the "new relative" baseline.
///
/// The server stays the authority: [replaceLinks] swaps the links and the
/// notes wholesale. Notes are changed online only; the cache is written
/// after the server accepted a change ([saveNote], [dropNote]). A note may
/// carry health context: nothing here logs it.
class RelativesRepository {
  /// Creates the repository.
  RelativesRepository(this._db, this._syncState);

  final AppDatabase _db;
  final SyncStateStore _syncState;

  /// Stored links, oldest first.
  Stream<List<RelativeLinkRow>> watchLinks() {
    return (_db.select(_db.relativeLinks)
          ..orderBy([
            (row) => OrderingTerm.asc(row.createdAt),
            (row) => OrderingTerm.asc(row.id),
          ]))
        .watch();
  }

  /// Stored links, oldest first.
  Future<List<RelativeLinkRow>> links() {
    return (_db.select(_db.relativeLinks)
          ..orderBy([
            (row) => OrderingTerm.asc(row.createdAt),
            (row) => OrderingTerm.asc(row.id),
          ]))
        .get();
  }

  /// Stored notes by subject profile id.
  Stream<Map<String, String>> watchNotes() {
    return _db.select(_db.relativeNotes).watch().map(
          (rows) => {for (final row in rows) row.profileId: row.note},
        );
  }

  /// Stores [note] as the server returned it.
  Future<void> saveNote(RelativeNote note) async {
    await _db.into(_db.relativeNotes).insertOnConflictUpdate(_note(note));
  }

  /// Drops the stored note about [profileId].
  Future<void> dropNote(String profileId) async {
    await (_db.delete(_db.relativeNotes)
          ..where((row) => row.profileId.equals(profileId)))
        .go();
  }

  /// Updates of the "new relative" baseline.
  Stream<DateTime?> watchSeenAt() => _syncState.watchRelativesSeenAt();

  /// Replaces the stored links and notes with [grants]. Returns the ids of outgoing
  /// links that were inactive before and are active now (a relative whose
  /// account was restored), so the owner is told even without a push.
  ///
  /// The first refresh sets the "new relative" baseline to the newest link
  /// that exists, so links from before this device looked are not new.
  Future<Set<String>> replaceLinks(GrantList grants) {
    return _db.transaction(() async {
      final before = {
        for (final row in await links())
          if (row.direction == LinkDirection.outgoing) row.id: row.active,
      };
      await _db.delete(_db.relativeLinks).go();
      await _db.delete(_db.relativeNotes).go();
      await _db.batch((batch) {
        batch.insertAll(_db.relativeLinks, [
          for (final grant in grants.outgoing) _outgoing(grant),
          for (final grant in grants.incoming) _incoming(grant),
        ]);
        batch.insertAll(
          _db.relativeNotes,
          [for (final note in grants.notes) _note(note)],
          mode: InsertMode.insertOrReplace,
        );
      });
      if (await _syncState.relativesSeenAt() == null) {
        await _syncState.advanceRelativesSeenAt(_newest(grants.outgoing));
      }
      return {
        for (final grant in grants.outgoing)
          if (grant.active && before[grant.id] == false) grant.id,
      };
    });
  }

  /// The owner has looked at the links: everything up to now is not new.
  Future<void> markSeen() async {
    final outgoing = [
      for (final row in await links())
        if (row.direction == LinkDirection.outgoing) row.createdAt,
    ];
    if (outgoing.isEmpty) {
      return;
    }
    outgoing.sort();
    await _syncState.advanceRelativesSeenAt(
      DateTime.fromMicrosecondsSinceEpoch(outgoing.last, isUtc: true),
    );
  }

  /// Drops the stored link [id] (revoked or left; the next refresh
  /// confirms), and the note about its person when no other link relates
  /// them any more: the server deletes it in the same step (docs/adr/0020
  /// §4).
  Future<void> forget(String id) {
    return _db.transaction(() async {
      final link = await (_db.select(_db.relativeLinks)
            ..where((row) => row.id.equals(id)))
          .getSingleOrNull();
      await (_db.delete(_db.relativeLinks)..where((row) => row.id.equals(id)))
          .go();
      final subject = link?.counterpartProfileId;
      if (subject == null) {
        return;
      }
      final others = await (_db.select(_db.relativeLinks)
            ..where((row) => row.counterpartProfileId.equals(subject)))
          .get();
      if (others.isEmpty) {
        await dropNote(subject);
      }
    });
  }

  /// Applies the grantee's alert choice to the stored incoming link [id].
  Future<void> setNotifyMissed(String id, {required bool enabled}) async {
    await (_db.update(_db.relativeLinks)..where((row) => row.id.equals(id)))
        .write(RelativeLinksCompanion(notifyMissed: Value(enabled)));
  }

  /// Applies a role change to the stored outgoing link [id].
  Future<void> setRole(String id, String role) async {
    await (_db.update(_db.relativeLinks)..where((row) => row.id.equals(id)))
        .write(RelativeLinksCompanion(role: Value(role)));
  }

  RelativeLinksCompanion _outgoing(OutgoingGrant grant) {
    return RelativeLinksCompanion.insert(
      id: grant.id,
      direction: LinkDirection.outgoing,
      profileId: grant.profileId,
      role: grant.role,
      counterpartName: Value(grant.granteeDisplayName),
      active: Value(grant.active),
      createdAt: grant.createdAt.microsecondsSinceEpoch,
      profileName: Value(grant.profileDisplayName),
      profileKind: Value(grant.profileKind),
      counterpartProfileId: Value(grant.granteeProfileId),
    );
  }

  RelativeLinksCompanion _incoming(IncomingGrant grant) {
    return RelativeLinksCompanion.insert(
      id: grant.id,
      direction: LinkDirection.incoming,
      profileId: grant.profileId,
      role: grant.role,
      counterpartName: Value(grant.ownerDisplayName),
      notifyMissed: Value(grant.notifyMissed),
      createdAt: grant.createdAt.microsecondsSinceEpoch,
      profileName: Value(grant.profileDisplayName),
      profileKind: Value(grant.profileKind),
      // The owner's profile stands for them (or for the managed person).
      counterpartProfileId: Value(grant.profileId),
    );
  }

  RelativeNotesCompanion _note(RelativeNote note) {
    return RelativeNotesCompanion.insert(
      profileId: note.profileId,
      note: note.note,
      updatedAt: note.updatedAt.microsecondsSinceEpoch,
    );
  }

  /// The newest creation instant of [grants]; the epoch without any, so
  /// that the first link ever made is new.
  DateTime _newest(List<OutgoingGrant> grants) {
    var newest = DateTime.fromMicrosecondsSinceEpoch(0, isUtc: true);
    for (final grant in grants) {
      if (grant.createdAt.isAfter(newest)) {
        newest = grant.createdAt;
      }
    }
    return newest;
  }
}
