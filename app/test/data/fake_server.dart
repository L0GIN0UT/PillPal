import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fake_sync_store.dart';

export 'fake_sync_store.dart' show Json, MutationResponder;

/// A recorded request.
class RecordedRequest {
  RecordedRequest(this.method, this.path, this.query, this.headers, this.body);

  final String method;
  final String path;
  final Map<String, String> query;
  final Map<String, String> headers;
  final Object? body;
}

class _User {
  _User(this.id, this.password, {this.verified = false});

  final String id;
  final String password;
  bool verified;
}

/// In-memory emulation of the PillPal API behind a MockClient.
///
/// Implements the documented contract (backend/README.md): JWT access tokens
/// carrying `sub` and `region`, refresh rotation, the error envelope, a
/// `Date` header from the server clock [now], multiple accounts with one
/// global journal ([FakeSyncStore]), and the entity GET endpoints.
class FakeServer {
  FakeServer({DateTime Function()? now})
      : now = now ?? (() => DateTime.now().toUtc()) {
    sync = FakeSyncStore(this.now);
    _users[defaultEmail] = _User(defaultUserId, 'correct-pass', verified: true);
    issueTokens(defaultUserId);
  }

  static const String defaultUserId = '0a000000-0000-4000-8000-00000000000a';
  static const String defaultEmail = 'demo@example.com';
  static const String verificationCode = '123456';

  final DateTime Function() now;
  late final FakeSyncStore sync;
  final Map<String, _User> _users = {};
  final Map<String, String> _accessTokens = {};
  final Map<String, String> _refreshTokens = {};
  int _serial = 0;

  /// The most recently issued pair.
  late String access;
  late String refresh;
  int refreshCalls = 0;

  /// Holds refresh responses while set.
  Completer<void>? refreshGate;

  /// Holds push responses while set (the request is counted as in flight).
  Completer<void>? pushGate;

  /// Push requests being served right now, and the most there ever were.
  int pushesInFlight = 0;
  int maxPushesInFlight = 0;

  /// Emulates the backend's refresh reuse window (3.7): a repeat of an
  /// already rotated token returns the same new pair instead of an error.
  bool refreshReuseWindow = false;
  final Map<String, Json> _rotated = {};

  final List<RecordedRequest> requests = [];

  late final http.Client client = MockClient(_handle);

  // -- convenience for tests ------------------------------------------------

  List<List<Json>> get pushes => sync.pushes;
  set responder(MutationResponder? value) => sync.responder = value;
  set failPullAtCursor(int? value) => sync.failPullAtCursor = value;

  /// Pull requests (bodies), oldest first.
  List<Json> get pulls => [
        for (final r in requests)
          if (r.path == '/v1/sync/pull') r.body! as Json,
      ];

  /// The cursors of every pull request, oldest first.
  List<Map<String, Object?>> get pullCursors =>
      [for (final body in pulls) body['cursors']! as Json];

  /// Gives [grantee] [role] on [profileId] (see [FakeSyncStore.grant]).
  void grant(String profileId, String grantee, String role) =>
      sync.grant(profileId, grantee, role);

  /// Seeds an entity of the default user.
  void seed(
    String entity,
    String id, {
    Json? data,
    DateTime? key,
    String device = 'other-device',
    bool deleted = false,
    String user = defaultUserId,
  }) =>
      sync.seed(
        user,
        entity,
        id,
        data: data,
        key: key,
        device: device,
        deleted: deleted,
      );

  Json? dataOf(String entity, String id, {String user = defaultUserId}) =>
      sync.dataOf(user, entity, id);

  /// A JWT-shaped access token (unsigned) for [userId].
  String _jwt(String userId) {
    String part(Json json) =>
        base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
    return '${part({'alg': 'none'})}.'
        '${part({'sub': userId, 'region': 'ru', 'n': ++_serial})}.fake';
  }

  /// Issues a token pair for [userId] (it becomes [access]/[refresh]).
  Json issueTokens(String userId) {
    access = _jwt(userId);
    refresh = 'refresh-${++_serial}';
    _accessTokens[access] = userId;
    _refreshTokens[refresh] = userId;
    return {
      'access_token': access,
      'refresh_token': refresh,
      'token_type': 'bearer',
      'expires_in': 900,
    };
  }

  /// Invalidates [access] (as if it expired); [refresh] stays valid.
  void expireAccess() {
    final user = _accessTokens.remove(access)!;
    access = _jwt(user);
    _accessTokens[access] = user;
  }

  /// Makes [refresh] belong to [userId] (a misbehaving server).
  void reassignRefresh(String userId) => _refreshTokens[refresh] = userId;

  /// Revokes every refresh token (e.g. reuse detected elsewhere).
  void revokeRefreshTokens() => _refreshTokens.clear();

  /// Registers a verified account directly.
  void addUser(String email, String password, String userId) {
    _users[email] = _User(userId, password, verified: true);
  }

  // -- HTTP -----------------------------------------------------------------

  Future<http.Response> _handle(http.Request request) async {
    final Object? body = request.bodyBytes.isEmpty
        ? null
        : jsonDecode(utf8.decode(request.bodyBytes));
    requests.add(
      RecordedRequest(
        request.method,
        request.url.path,
        request.url.queryParameters,
        request.headers,
        body,
      ),
    );
    try {
      return await _route(request, body);
    } on FakeHttpError catch (error) {
      return _error(error.status, error.code);
    }
  }

  Future<http.Response> _route(http.Request request, Object? body) async {
    final path = request.url.path;
    if (path.startsWith('/v1/auth/')) {
      return _auth(path, body! as Json);
    }
    final header = request.headers['authorization'] ?? '';
    final user = _accessTokens[header.replaceFirst('Bearer ', '')];
    if (user == null) {
      return _error(401, 'unauthorized');
    }
    final device = request.headers['x-device-id']!;
    if (path == '/v1/sync/push') {
      final mutations = [
        for (final item in (body! as Json)['mutations']! as List<Object?>)
          item! as Json,
      ];
      pushesInFlight++;
      if (pushesInFlight > maxPushesInFlight) {
        maxPushesInFlight = pushesInFlight;
      }
      try {
        final gate = pushGate;
        if (gate != null) {
          await gate.future;
        }
        return _json(200, sync.push(user, device, mutations));
      } finally {
        pushesInFlight--;
      }
    }
    if (path == '/v1/sync/pull') {
      return _json(200, sync.pullScoped(user, body! as Json));
    }
    if (path == '/v1/me') {
      final email = _users.entries.firstWhere((e) => e.value.id == user).key;
      return _json(200, {
        'id': user,
        'email': email,
        'email_verified': true,
        'region': 'ru',
        'locale': 'ru',
        'created_at': '2026-10-16T08:00:00Z',
      });
    }
    final match =
        RegExp(r'^/v1/(profiles|medications|schedules|dose-events)/([^/]+)$')
            .firstMatch(path);
    if (match != null) {
      final entity = switch (match[1]) {
        'profiles' => 'profile',
        'medications' => 'medication',
        'schedules' => 'schedule',
        _ => 'dose_event',
      };
      final data = sync.get(user, entity, match[2]!);
      return data == null ? _error(404, 'not_found') : _json(200, data);
    }
    return _error(404, 'not_found');
  }

  Future<http.Response> _auth(String path, Json body) async {
    final email = body['email'] as String?;
    final user = email == null ? null : _users[email];
    switch (path) {
      case '/v1/auth/register':
        _users.putIfAbsent(
          email!,
          () => _User('u-${++_serial}', body['password']! as String),
        );
        return _json(202, {'status': 'verification_sent'});
      case '/v1/auth/verify-email/resend':
        return _json(202, {'status': 'accepted'});
      case '/v1/auth/verify-email':
        if (user == null || body['code'] != verificationCode) {
          return _error(400, 'invalid_code');
        }
        user.verified = true;
        return _json(200, issueTokens(user.id));
      case '/v1/auth/login':
        if (user == null || user.password != body['password']) {
          return _error(401, 'invalid_credentials');
        }
        if (!user.verified) {
          return _error(403, 'email_not_verified');
        }
        return _json(200, issueTokens(user.id));
      case '/v1/auth/logout':
        _refreshTokens.remove(body['refresh_token']);
        return http.Response('', 204, headers: _headers());
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
    final old = body['refresh_token']! as String;
    final user = _refreshTokens.remove(old);
    if (user == null) {
      final repeated = _rotated[old];
      if (refreshReuseWindow && repeated != null) {
        return _json(200, repeated);
      }
      return _error(401, 'token_reused');
    }
    final pair = issueTokens(user);
    _rotated[old] = pair;
    return _json(200, pair);
  }

  Map<String, String> _headers() => {
        'content-type': 'application/json',
        'date': HttpDate.format(now()),
      };

  http.Response _error(int status, String code) => _json(status, {
        'error': {'code': code, 'message': 'Fixed server message'},
      });

  http.Response _json(int status, Json body) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: _headers(),
      );
}
