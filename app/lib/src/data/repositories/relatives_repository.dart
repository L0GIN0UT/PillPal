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
/// Family tab works offline, and the "new relative" baseline.
///
/// The server stays the authority: [replaceLinks] swaps the whole table.
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

  /// Updates of the "new relative" baseline.
  Stream<DateTime?> watchSeenAt() => _syncState.watchRelativesSeenAt();

  /// Replaces the stored links with [grants]. Returns the ids of outgoing
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
      await _db.batch((batch) {
        batch.insertAll(_db.relativeLinks, [
          for (final grant in grants.outgoing) _outgoing(grant),
          for (final grant in grants.incoming) _incoming(grant),
        ]);
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

  /// Drops the stored link [id] (revoked or left; the next refresh confirms).
  Future<void> forget(String id) async {
    await (_db.delete(_db.relativeLinks)..where((row) => row.id.equals(id)))
        .go();
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
