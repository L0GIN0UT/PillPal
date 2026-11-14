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
/// after the server accepted a change ([saveNoteFor], [dropNoteFor]), and
/// only while the account that asked is still the bound one. A note may
/// carry health context: nothing here logs it.
class RelativesRepository {
  /// Creates the repository.
  RelativesRepository(this._db, this._syncState);

  final AppDatabase _db;
  final SyncStateStore _syncState;

  /// Note writes accepted by the server in this process, by subject, with
  /// the sequence number of the write (null note: deleted). A refresh that
  /// was asked before a write re-applies it ([replaceLinksFor]).
  final Map<String, (int, RelativeNote?)> _noteWrites = {};
  int _noteSequence = 0;

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

  /// Where the note writes stand now: pass it to [replaceLinksFor] of a
  /// refresh asked from here on.
  int get noteWriteMark => _noteSequence;

  /// Stores [note] as the server returned it to [user], in one transaction
  /// with the check that [user] is still the bound account. Returns whether
  /// it was stored (not after a sign-out or another account's sign-in).
  Future<bool> saveNoteFor(String? user, RelativeNote note) {
    return _db.transaction(() async {
      if (user == null || await _syncState.boundUserId() != user) {
        return false;
      }
      await _db.into(_db.relativeNotes).insertOnConflictUpdate(_note(note));
      _noteWrites[note.profileId] = (++_noteSequence, note);
      return true;
    });
  }

  /// Drops the stored note about [profileId] after the server deleted it
  /// for [user]; like [saveNoteFor], only while [user] is still bound.
  Future<bool> dropNoteFor(String? user, String profileId) {
    return _db.transaction(() async {
      if (user == null || await _syncState.boundUserId() != user) {
        return false;
      }
      await _dropNote(profileId);
      _noteWrites[profileId] = (++_noteSequence, null);
      return true;
    });
  }

  Future<void> _dropNote(String profileId) async {
    await (_db.delete(_db.relativeNotes)
          ..where((row) => row.profileId.equals(profileId)))
        .go();
  }

  /// Updates of the "new relative" baseline.
  Stream<DateTime?> watchSeenAt() => _syncState.watchRelativesSeenAt();

  /// [replaceLinksFor] without the account check (tests and tools that own
  /// the database).
  Future<Set<String>> replaceLinks(GrantList grants) {
    return _db.transaction(() => _replace(grants, null));
  }

  /// Replaces the stored links and notes with [grants], the answer to
  /// [user], in one transaction with the check that [user] is still the
  /// bound account; null when it is not (nothing written). Otherwise the
  /// ids of outgoing links that were inactive before and are active now (a
  /// relative whose account was restored), so the owner is told even
  /// without a push.
  ///
  /// Note writes made after [notesSince] ([noteWriteMark] when the refresh
  /// was asked) are newer than the answer and are kept.
  ///
  /// The first refresh sets the "new relative" baseline to the newest link
  /// that exists, so links from before this device looked are not new.
  Future<Set<String>?> replaceLinksFor(
    String? user,
    GrantList grants, {
    int? notesSince,
  }) {
    return _db.transaction(() async {
      if (await _syncState.boundUserId() != user) {
        return null;
      }
      return _replace(grants, notesSince);
    });
  }

  Future<Set<String>> _replace(GrantList grants, int? notesSince) async {
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
        [for (final note in _notesOf(grants, notesSince).values) _note(note)],
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
  }

  /// The notes of [grants] with the writes made after [since] on top, for
  /// the people the answer still relates.
  Map<String, RelativeNote> _notesOf(GrantList grants, int? since) {
    final notes = {for (final note in grants.notes) note.profileId: note};
    if (since == null) {
      return notes;
    }
    final related = {
      for (final grant in grants.outgoing)
        if (grant.granteeProfileId case final id?) id,
      for (final grant in grants.incoming) grant.profileId,
    };
    for (final MapEntry(key: subject, value: (sequence, note))
        in _noteWrites.entries) {
      if (sequence <= since || !related.contains(subject)) {
        continue;
      }
      if (note == null) {
        notes.remove(subject);
      } else {
        notes[subject] = note;
      }
    }
    return notes;
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
        await _dropNote(subject);
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
