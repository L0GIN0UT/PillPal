import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

typedef Json = Map<String, Object?>;

/// Overrides the server's answer to one pushed mutation (null: default).
typedef MutationResponder = Json? Function(Json mutation);

/// A recorded request.
class RecordedRequest {
  RecordedRequest(this.method, this.path, this.query, this.headers, this.body);

  final String method;
  final String path;
  final Map<String, String> query;
  final Map<String, String> headers;
  final Object? body;
}

class _Stored {
  _Stored(this.data, this.key, this.device);

  Json? data; // null for tombstones
  DateTime? key;
  String? device;
  DateTime? deletedAt;
}

/// In-memory emulation of the PillPal API (auth + sync) behind a MockClient.
///
/// Implements the documented contract (backend/README.md): error envelope,
/// refresh rotation with reuse detection, last-write-wins on
/// (client_updated_at, X-Device-ID), final deletes, idempotent dose events and
/// a journal with cursor paging.
class FakeServer {
  int _generation = 1;
  String access = 'access-1';
  String refresh = 'refresh-1';
  int refreshCalls = 0;

  /// Completes refresh responses when set (to hold refreshes in flight).
  Completer<void>? refreshGate;

  final List<RecordedRequest> requests = [];
  final List<List<Json>> pushes = [];
  final Map<String, _Stored> _entities = {};
  final List<(int, String, String)> _journal = [];
  int _seq = 0;
  MutationResponder? responder;

  /// Pull requests with this cursor fail with 503.
  int? failPullAtCursor;

  late final http.Client client = MockClient(_handle);

  /// A token pair JSON for the current generation.
  Json tokenJson() => {
        'access_token': access,
        'refresh_token': refresh,
        'token_type': 'bearer',
        'expires_in': 900,
      };

  /// Invalidates the current access token (as if it expired).
  void expireAccess() {
    _generation++;
    access = 'access-$_generation-rotated';
  }

  /// Stores server-side state and journals it, as another device would.
  void seed(
    String entity,
    String id, {
    Json? data,
    DateTime? key,
    String device = 'other-device',
    bool deleted = false,
  }) {
    final stored = _Stored(
      deleted ? null : {'id': id, ...?data},
      key,
      entity == 'dose_event' ? null : device,
    );
    if (deleted) {
      stored.deletedAt = key;
    }
    _entities['$entity/$id'] = stored;
    _journal.add((++_seq, entity, id));
  }

  /// Server copy of an entity's data (null if unknown or tombstone).
  Json? dataOf(String entity, String id) => _entities['$entity/$id']?.data;

  /// Whether the server has a tombstone for the entity.
  bool isDeleted(String entity, String id) =>
      _entities['$entity/$id']?.deletedAt != null;

  Future<http.Response> _handle(http.Request request) async {
    final Object? body = request.bodyBytes.isEmpty
        ? null
        : jsonDecode(utf8.decode(request.bodyBytes));
    requests.add(RecordedRequest(
      request.method,
      request.url.path,
      request.url.queryParameters,
      request.headers,
      body,
    ));
    final path = request.url.path;
    if (path.startsWith('/v1/auth/')) {
      return _auth(path, body as Json);
    }
    if (request.headers['authorization'] != 'Bearer $access') {
      return _error(401, 'unauthorized');
    }
    switch (path) {
      case '/v1/sync/push':
        return _push(body as Json, request.headers['x-device-id']!);
      case '/v1/sync/pull':
        return _pull(request.url.queryParameters);
      case '/v1/me':
        return _json(200, {
          'id': 'user-1',
          'email': 'demo@example.com',
          'email_verified': true,
          'region': 'ru',
          'locale': 'ru',
          'created_at': '2026-10-16T08:00:00Z',
        });
    }
    return _error(404, 'not_found');
  }

  Future<http.Response> _auth(String path, Json body) async {
    switch (path) {
      case '/v1/auth/register':
        return _json(202, {'status': 'verification_sent'});
      case '/v1/auth/verify-email/resend':
        return _json(202, {'status': 'accepted'});
      case '/v1/auth/verify-email':
        return body['code'] == '123456'
            ? _json(200, tokenJson())
            : _error(400, 'invalid_code');
      case '/v1/auth/login':
        if (body['password'] == 'unverified-pass') {
          return _error(403, 'email_not_verified');
        }
        return body['password'] == 'correct-pass'
            ? _json(200, tokenJson())
            : _error(401, 'invalid_credentials');
      case '/v1/auth/logout':
        return http.Response('', 204);
      case '/v1/auth/refresh':
        return _refresh(body);
    }
    return _error(404, 'not_found');
  }

  Future<http.Response> _refresh(Json body) async {
    refreshCalls++;
    final gate = refreshGate;
    if (gate != null) {
      await gate.future;
    }
    if (body['refresh_token'] != refresh) {
      return _error(401, 'token_reused');
    }
    _generation++;
    access = 'access-$_generation';
    refresh = 'refresh-$_generation';
    return _json(200, tokenJson());
  }

  http.Response _push(Json body, String device) {
    final mutations = [
      for (final item in body['mutations']! as List<Object?>) item! as Json,
    ];
    pushes.add(mutations);
    return _json(200, {
      'results': [
        for (final mutation in mutations)
          responder?.call(mutation) ?? _apply(mutation, device),
      ],
    });
  }

  Json _result(Json m, String status, {String? code, Json? current}) => {
        'entity': m['entity'],
        'id': m['id'],
        'status': status,
        'code': code,
        'version': 1,
        'current': current,
      };

  Json _apply(Json m, String device) {
    final entity = m['entity']! as String;
    final id = m['id']! as String;
    final key = DateTime.parse(m['client_updated_at']! as String);
    final stored = _entities['$entity/$id'];
    if (entity == 'dose_event') {
      if (stored == null) {
        final data = m['data']! as Json;
        _entities['$entity/$id'] = _Stored({
          'id': id,
          'profile_id': 'profile-of-${data['medication_id']}',
          ...data,
          'recorded_at': '2026-10-16T09:00:00.000001Z',
          'device_id': device,
        }, null, null);
        _journal.add((++_seq, entity, id));
      }
      return _result(m, 'applied');
    }
    if (m['op'] == 'delete') {
      if (stored != null && stored.deletedAt == null) {
        stored
          ..data = null
          ..deletedAt = key;
        _journal.add((++_seq, entity, id));
      }
      return _result(m, 'applied');
    }
    if (stored != null) {
      if (stored.deletedAt != null) {
        return _result(m, 'ignored_stale',
            code: 'deleted', current: _state(stored));
      }
      final order = _compare(key, device, stored);
      if (order < 0) {
        return _result(m, 'ignored_stale', current: _state(stored));
      }
      if (order == 0) {
        return _result(m, 'applied');
      }
    }
    _entities['$entity/$id'] = _Stored(
      {'id': id, ...m['data']! as Json},
      key,
      device,
    );
    _journal.add((++_seq, entity, id));
    return _result(m, 'applied');
  }

  int _compare(DateTime key, String device, _Stored stored) {
    final byKey = key.compareTo(stored.key!);
    return byKey != 0 ? byKey : device.compareTo(stored.device!);
  }

  Json _state(_Stored stored) => {
        'op': stored.deletedAt == null ? 'upsert' : 'delete',
        'data': stored.data,
        'client_updated_at': stored.key?.toUtc().toIso8601String(),
        'updated_by_device': stored.device,
        'deleted_at': stored.deletedAt?.toUtc().toIso8601String(),
      };

  http.Response _pull(Map<String, String> query) {
    final cursor = int.parse(query['cursor'] ?? '0');
    if (cursor == failPullAtCursor) {
      return _error(503, 'unavailable');
    }
    final limit = int.parse(query['limit'] ?? '100');
    final after = _journal.where((entry) => entry.$1 > cursor).toList();
    final page = after.take(limit).toList();
    return _json(200, {
      'changes': [
        for (final (seq, entity, id) in page)
          {
            'seq': seq,
            'entity': entity,
            'id': id,
            ..._state(_entities['$entity/$id']!),
          },
      ],
      'next_cursor': page.isEmpty ? cursor : page.last.$1,
      'has_more': after.length > limit,
    });
  }

  http.Response _error(int status, String code) => _json(status, {
        'error': {'code': code, 'message': 'Fixed server message'},
      });

  http.Response _json(int status, Json body) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json'},
      );
}
