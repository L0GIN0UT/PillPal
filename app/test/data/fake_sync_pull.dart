part of 'fake_sync_store.dart';

/// The scoped pull of [FakeSyncStore] (`POST /v1/sync/pull`).
extension FakeScopedPull on FakeSyncStore {
  /// The scopes [user] can access: owned profiles (a deleted one only while
  /// the sent cursor is below its tombstone, like the server) and granted
  /// ones.
  Map<String, _Access> _accessOf(String user, Map<String, int> cursors) {
    final result = <String, _Access>{};
    for (final MapEntry(key: path, value: stored) in _entities.entries) {
      final parts = path.split('/');
      if (parts[1] != 'profile') {
        continue;
      }
      final (owner, id) = (parts[0], parts[2]);
      final kind = (stored.payload?['kind'] as String?) ?? 'managed';
      if (owner == user) {
        final tombstoneSeq = _lastSeq(id);
        final pending = (cursors[id] ?? tombstoneSeq) < tombstoneSeq;
        if (stored.live || pending) {
          result[id] = _Access('owner', kind, owner);
        }
      } else if (stored.live && _grants[id]?[user] != null) {
        result[id] = _Access(_grants[id]![user]!, kind, owner);
      }
    }
    return result;
  }

  int _lastSeq(String scope) {
    var last = 0;
    for (final row in _journal) {
      if (row.scope == scope && row.seq > last) {
        last = row.seq;
      }
    }
    return last;
  }

  /// `POST /v1/sync/pull`: the journal of the requested, accessible scopes
  /// after their cursors, `limit` rows per page; several rows of one entity
  /// collapse into one change, ordered parents first (profile, medication,
  /// schedule, dose event). A scope's new cursor is the newest row read.
  Json pullScoped(String user, Json body) {
    final cursors = {
      for (final MapEntry(:key, :value) in (body['cursors']! as Json).entries)
        key: value! as int,
    };
    final limit = body['limit'] as int? ?? 100;
    if (cursors.values.contains(failPullAtCursor)) {
      throw FakeHttpError(503, 'unavailable');
    }
    if (expireCursorOnce && cursors.values.any((cursor) => cursor > 0)) {
      expireCursorOnce = false;
      throw FakeHttpError(410, 'cursor_expired');
    }
    final access = _accessOf(user, cursors);
    final after = [
      for (final row in _journal)
        if (access.containsKey(row.scope) &&
            cursors.containsKey(row.scope) &&
            row.seq > cursors[row.scope]!)
          row,
    ];
    final page = after.take(limit).toList();
    final cursor = {...cursors};
    for (final row in page) {
      cursor[row.scope] = row.seq;
    }
    final first = <String, int>{};
    final last = <String, _Row>{};
    for (final row in page) {
      first.putIfAbsent('${row.entity}/${row.id}', () => row.seq);
      last['${row.entity}/${row.id}'] = row;
    }
    final order = first.keys.toList()
      ..sort((a, b) {
        final byRank = _entityRank[last[a]!.entity]!
            .compareTo(_entityRank[last[b]!.entity]!);
        return byRank != 0 ? byRank : first[a]!.compareTo(first[b]!);
      });
    return {
      'scopes': [
        for (final MapEntry(key: id, value: grant) in access.entries)
          {
            'profile_id': id,
            'role': grant.role,
            'kind': grant.kind,
            'archived': _archived.contains(id),
            'archive_purge_after': null,
            'owner_last_seen_at': null,
            'cursor': cursors.containsKey(id) ? cursor[id] : null,
            'backfill_until': _unfinishedBackfill(id, cursor[id]),
          },
      ],
      'revoked': [
        for (final id in cursors.keys)
          if (!access.containsKey(id)) id,
      ],
      'changes': [
        for (final key in order)
          {
            'seq': last[key]!.seq,
            'scope': last[key]!.scope,
            'entity': last[key]!.entity,
            'id': last[key]!.id,
            ..._state(_entities['${last[key]!.owner}/$key']!),
          },
      ],
      'has_more': after.length > limit,
    };
  }

  int? _unfinishedBackfill(String scope, int? cursor) {
    final until = _backfill[scope];
    return until != null && (cursor ?? 0) < until ? until : null;
  }
}
