typedef Json = Map<String, Object?>;

/// Overrides the server's answer to one pushed mutation (null: default).
typedef MutationResponder = Json? Function(Json mutation);

/// An HTTP error raised by the fake.
class FakeHttpError implements Exception {
  FakeHttpError(this.status, this.code);

  final int status;
  final String code;
}

class _Stored {
  _Stored({
    this.data,
    this.payload,
    this.key,
    this.device,
    this.parentId,
    this.scope,
  });

  Json? data; // `*Out` state; null for tombstones
  Json? payload; // last applied `*Data` (idempotent replay / key_conflict)
  DateTime? key;
  String? device;
  String? parentId; // profile of a medication, medication of a schedule/event
  String? scope; // the profile the entity belongs to (its sync scope)
  DateTime? deletedAt;

  bool get live => deletedAt == null;
}

/// One journal row.
class _Row {
  _Row(this.seq, this.owner, this.entity, this.id, this.scope);

  final int seq;
  final String owner;
  final String entity;
  final String id;
  final String scope;
}

/// What an account may do with one scope.
class _Access {
  _Access(this.role, this.kind, this.owner);

  final String role;
  final String kind;
  final String owner;
}

const Map<String, int> _entityRank = {
  'profile': 0,
  'medication': 1,
  'schedule': 2,
  'dose_event': 3,
};

bool _jsonEquals(Object? a, Object? b) {
  if (a is Map<String, Object?> && b is Map<String, Object?>) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _jsonEquals(a[k], b[k]));
  }
  if (a is List<Object?> && b is List<Object?>) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEquals(a[i], b[i])) {
        return false;
      }
    }
    return true;
  }
  return a == b;
}

/// The sync half of [FakeServer]: per-user entities, a global journal keyed
/// by profile (scope) and the push/pull rules of backend/README.md ("Sync
/// protocol"). Other accounts see a scope through [grant]; their rows are
/// seeded as the server would project them (the fake does not project).
class FakeSyncStore {
  FakeSyncStore(this.now);

  final DateTime Function() now;
  final Map<String, _Stored> _entities = {};
  final List<_Row> _journal = [];
  final Map<String, Map<String, String>> _grants = {};
  final Set<String> _archived = {};
  final Map<String, int> _backfill = {};
  int _seq = 0;

  final List<List<Json>> pushes = [];
  MutationResponder? responder;

  /// Pull requests carrying this cursor fail with 503.
  int? failPullAtCursor;

  /// The next pull with a cursor > 0 answers `410 cursor_expired`.
  bool expireCursorOnce = false;

  static const Duration _maxSkew = Duration(minutes: 10);

  String _k(String user, String entity, String id) => '$user/$entity/$id';

  void _journalAdd(String user, String entity, String id) {
    final scope = _entities[_k(user, entity, id)]!.scope!;
    _journal.add(_Row(++_seq, user, entity, id, scope));
  }

  /// Gives [grantee] [role] (`viewer`, `editor`, `guardian`) on [profileId].
  void grant(String profileId, String grantee, String role) {
    (_grants[profileId] ??= {})[grantee] = role;
  }

  /// Takes [grantee]'s access to [profileId] away.
  void revoke(String profileId, String grantee) {
    _grants[profileId]?.remove(grantee);
  }

  /// Marks [profileId] as a read-only archive (or not).
  void setArchived(String profileId, {required bool archived}) {
    archived ? _archived.add(profileId) : _archived.remove(profileId);
  }

  /// Makes pulls of [profileId] report an unfinished backfill up to [seq].
  void setBackfillUntil(String profileId, int seq) {
    _backfill[profileId] = seq;
  }

  /// The journal head.
  int get head => _seq;

  String _scopeOf(String user, String entity, String id, Json? data) {
    switch (entity) {
      case 'profile':
        return id;
      case 'medication':
        return data!['profile_id']! as String;
      case 'schedule':
        final medication = _entities[
            _k(user, 'medication', data!['medication_id']! as String)];
        return medication!.scope!;
      default:
        final direct = data!['profile_id'];
        if (direct is String) {
          return direct;
        }
        final medication =
            _entities[_k(user, 'medication', data['medication_id']! as String)];
        return medication!.scope!;
    }
  }

  /// Stores state as another device would, and journals it.
  void seed(
    String user,
    String entity,
    String id, {
    Json? data,
    DateTime? key,
    String device = 'other-device',
    bool deleted = false,
    String? parentId,
  }) {
    final existing = _entities[_k(user, entity, id)];
    final stored = _Stored(
      data: deleted ? null : {'id': id, ...?data},
      payload: data,
      key: key,
      device: entity == 'dose_event' ? null : device,
      parentId: parentId ??
          (data?['profile_id'] ?? data?['medication_id']) as String?,
      scope: existing?.scope ?? _scopeOf(user, entity, id, data),
    );
    if (deleted) {
      stored.deletedAt = key;
    }
    _entities[_k(user, entity, id)] = stored;
    _journalAdd(user, entity, id);
  }

  Json? dataOf(String user, String entity, String id) =>
      _entities[_k(user, entity, id)]?.data;

  bool isDeleted(String user, String entity, String id) =>
      _entities[_k(user, entity, id)]?.deletedAt != null;

  /// `GET /v1/<entity>/{id}`: live state or null (404).
  Json? get(String user, String entity, String id) {
    final stored = _entities[_k(user, entity, id)];
    return stored != null && stored.live ? stored.data : null;
  }

  Json push(String user, String device, List<Json> mutations) {
    pushes.add(mutations);
    return {
      'results': [
        for (final m in mutations)
          responder?.call(m) ?? _apply(user, device, m),
      ],
    };
  }

  Json _result(Json m, String status, {String? code, _Stored? current}) => {
        'entity': m['entity'],
        'id': m['id'],
        'status': status,
        'code': code,
        'version': 1,
        'current': current == null ? null : _state(current),
      };

  Json _apply(String user, String device, Json m) {
    final key = DateTime.parse(m['client_updated_at']! as String);
    if (key.isAfter(now().add(_maxSkew))) {
      return _result(m, 'rejected', code: 'clock_skew');
    }
    final entity = m['entity']! as String;
    final id = m['id']! as String;
    if (entity == 'dose_event') {
      return _applyDoseEvent(user, device, m);
    }
    final stored = _entities[_k(user, entity, id)];
    if (m['op'] == 'delete') {
      if (stored != null && stored.live) {
        _tombstone(user, entity, id, stored, key);
      }
      return _result(m, 'applied');
    }
    final data = m['data']! as Json;
    if (stored != null) {
      if (!stored.live) {
        return _result(m, 'ignored_stale', code: 'deleted', current: stored);
      }
      final byKey = key.compareTo(stored.key!);
      final order = byKey != 0 ? byKey : device.compareTo(stored.device!);
      if (order < 0) {
        return _result(m, 'ignored_stale', current: stored);
      }
      if (order == 0) {
        return _jsonEquals(stored.payload, data)
            ? _result(m, 'applied')
            : _result(m, 'rejected', code: 'key_conflict', current: stored);
      }
    } else {
      final parentCode = _parentProblem(user, entity, data);
      if (parentCode != null) {
        return _result(m, 'rejected', code: parentCode);
      }
    }
    _entities[_k(user, entity, id)] = _Stored(
      data: {'id': id, ...data, 'version': 1},
      payload: data,
      key: key,
      device: device,
      parentId: (data['profile_id'] ?? data['medication_id']) as String?,
      scope: stored?.scope ?? _scopeOf(user, entity, id, data),
    );
    _journalAdd(user, entity, id);
    return _result(m, 'applied');
  }

  String? _parentProblem(String user, String entity, Json data) {
    final (String, String)? parent = switch (entity) {
      'medication' => ('profile', data['profile_id']! as String),
      'schedule' => ('medication', data['medication_id']! as String),
      _ => null,
    };
    if (parent == null) {
      return null;
    }
    final stored = _entities[_k(user, parent.$1, parent.$2)];
    if (stored == null) {
      return 'parent_not_found';
    }
    return stored.live ? null : 'parent_deleted';
  }

  Json _applyDoseEvent(String user, String device, Json m) {
    if (m['op'] == 'delete') {
      return _result(m, 'rejected', code: 'append_only');
    }
    final id = m['id']! as String;
    final data = m['data']! as Json;
    final stored = _entities[_k(user, 'dose_event', id)];
    if (stored != null) {
      return _jsonEquals(stored.payload, data)
          ? _result(m, 'applied')
          : _result(m, 'rejected', code: 'idempotency_conflict');
    }
    // Tombstoned medications still accept events (history is kept).
    final medicationId = data['medication_id']! as String;
    final medication = _entities[_k(user, 'medication', medicationId)];
    if (medication == null) {
      return _result(m, 'rejected', code: 'parent_not_found');
    }
    if (DateTime.parse(data['at']! as String).isAfter(now().add(_maxSkew))) {
      return _result(m, 'rejected', code: 'validation_error');
    }
    _entities[_k(user, 'dose_event', id)] = _Stored(
      data: {
        'id': id,
        'profile_id': medication.parentId,
        ...data,
        'recorded_at': now().toIso8601String(),
        'device_id': device,
      },
      payload: data,
      parentId: medicationId,
      scope: medication.scope,
    );
    _journalAdd(user, 'dose_event', id);
    return _result(m, 'applied');
  }

  void _tombstone(
    String user,
    String entity,
    String id,
    _Stored stored,
    DateTime key,
  ) {
    stored
      ..data = null
      ..deletedAt = now();
    if (key.isAfter(stored.key!)) {
      stored.key = key;
    }
    _journalAdd(user, entity, id);
    final child = switch (entity) {
      'profile' => 'medication',
      'medication' => 'schedule',
      _ => null,
    };
    if (child == null) {
      return;
    }
    for (final MapEntry(key: k, value: v) in _entities.entries.toList()) {
      if (k.startsWith('$user/$child/') && v.parentId == id && v.live) {
        _tombstone(user, child, k.split('/').last, v, key);
      }
    }
  }

  Json _state(_Stored stored) => {
        'op': stored.live ? 'upsert' : 'delete',
        'data': stored.data,
        'client_updated_at': stored.key?.toUtc().toIso8601String(),
        'updated_by_device': stored.device,
        'deleted_at': stored.deletedAt?.toUtc().toIso8601String(),
      };

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
