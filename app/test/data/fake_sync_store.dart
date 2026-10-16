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
  _Stored({this.data, this.payload, this.key, this.device, this.parentId});

  Json? data; // `*Out` state; null for tombstones
  Json? payload; // last applied `*Data` (idempotent replay / key_conflict)
  DateTime? key;
  String? device;
  String? parentId; // profile of a medication, medication of a schedule/event
  DateTime? deletedAt;

  bool get live => deletedAt == null;
}

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

/// The sync half of [FakeServer]: per-user entities, a global journal and
/// the push/pull rules of backend/README.md ("Sync protocol").
class FakeSyncStore {
  FakeSyncStore(this.now);

  final DateTime Function() now;
  final Map<String, _Stored> _entities = {};
  final List<(int, String, String, String)> _journal = [];
  int _seq = 0;

  final List<List<Json>> pushes = [];
  MutationResponder? responder;

  /// Pull requests with this cursor fail with 503.
  int? failPullAtCursor;

  /// The next pull with a cursor > 0 answers `410 cursor_expired`.
  bool expireCursorOnce = false;

  static const Duration _maxSkew = Duration(minutes: 10);

  String _k(String user, String entity, String id) => '$user/$entity/$id';

  void _journalAdd(String user, String entity, String id) {
    _journal.add((++_seq, user, entity, id));
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
    final stored = _Stored(
      data: deleted ? null : {'id': id, ...?data},
      payload: data,
      key: key,
      device: entity == 'dose_event' ? null : device,
      parentId: parentId ??
          (data?['profile_id'] ?? data?['medication_id']) as String?,
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
        for (final m in mutations) responder?.call(m) ?? _apply(user, device, m),
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

  /// `GET /v1/sync/pull`: one user's journal after [cursor], with several
  /// rows of one entity collapsed at its first position (seq = its last).
  Json pull(String user, int cursor, int limit) {
    if (cursor == failPullAtCursor) {
      throw FakeHttpError(503, 'unavailable');
    }
    if (expireCursorOnce && cursor > 0) {
      expireCursorOnce = false;
      throw FakeHttpError(410, 'cursor_expired');
    }
    final after = [
      for (final row in _journal)
        if (row.$2 == user && row.$1 > cursor) row,
    ];
    final page = after.take(limit).toList();
    final first = <String, int>{};
    final last = <String, int>{};
    for (final (seq, _, entity, id) in page) {
      first.putIfAbsent('$entity/$id', () => seq);
      last['$entity/$id'] = seq;
    }
    final order = first.keys.toList()
      ..sort((a, b) => first[a]!.compareTo(first[b]!));
    return {
      'changes': [
        for (final key in order)
          {
            'seq': last[key],
            'entity': key.split('/').first,
            'id': key.split('/').last,
            ..._state(_entities['$user/$key']!),
          },
      ],
      'next_cursor': page.isEmpty ? cursor : page.last.$1,
      'has_more': after.length > limit,
    };
  }
}
