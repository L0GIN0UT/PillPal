import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// The consent endpoints of the API behind a `MockClient` handler
/// (`GET` and `POST /v1/me/consents`, ADR 0016 §2) for the tests of the
/// consent gate. Everything else answers 404.
class FakeConsentServer {
  /// Creates the server; [missing] is what `GET` reports.
  FakeConsentServer({List<String> missing = const []}) : missing = [...missing];

  /// Kinds the account still lacks; a successful `POST` removes its kind.
  List<String> missing;

  /// The versions asked for, per kind.
  Map<String, int> current = {'health_data': 1, 'terms': 1, 'privacy': 1};

  /// Every request, in order.
  final List<http.Request> requests = [];

  /// Kinds recorded through `POST`, in order.
  final List<String> accepted = [];

  /// `POST` of a kind answers this (status, code) instead of recording it.
  final Map<String, (int, String)> postFailures = {};

  /// `POST` of a kind throws a connection error.
  final Set<String> postOffline = {};

  /// `GET` throws a connection error.
  bool getOffline = false;

  /// `Retry-After` (seconds) sent with a failure of a `POST`.
  int? retryAfterSeconds;

  /// While set, the next `GET` answers what is true now but only after this
  /// completes (a slow response that is stale when it arrives).
  Completer<void>? holdNextGet;

  /// While set, every `POST` waits for it (a request in flight).
  Completer<void>? holdPosts;

  /// The requests as `METHOD path`.
  List<String> get calls => [
        for (final request in requests) '${request.method} ${request.url.path}',
      ];

  /// Bodies of the `POST`s, in order.
  List<Map<String, Object?>> get posted => [
        for (final request in requests)
          if (request.method == 'POST' && request.url.path == '/v1/me/consents')
            jsonDecode(request.body) as Map<String, Object?>,
      ];

  /// The `MockClient` handler.
  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    if (request.url.path == '/v1/auth/refresh') {
      // The session is gone for good: a rejected token is not retried.
      return _error(401, 'token_reused');
    }
    if (request.url.path != '/v1/me/consents') {
      return _error(404, 'not_found');
    }
    if (request.method == 'GET') {
      if (getOffline) {
        throw http.ClientException('offline');
      }
      final answer = _json(200, {
        'current': current,
        'records': <Object?>[],
        'missing': missing,
      });
      final hold = holdNextGet;
      holdNextGet = null;
      await hold?.future;
      return answer;
    }
    await holdPosts?.future;
    final body = jsonDecode(request.body) as Map<String, Object?>;
    final kind = body['kind']! as String;
    if (postOffline.contains(kind)) {
      throw http.ClientException('offline');
    }
    final failure = postFailures[kind];
    if (failure != null) {
      final response = _error(failure.$1, failure.$2);
      final seconds = retryAfterSeconds;
      if (seconds == null) {
        return response;
      }
      return http.Response(
        response.body,
        response.statusCode,
        headers: {...response.headers, 'retry-after': '$seconds'},
      );
    }
    if (current[kind] != body['version']) {
      return _error(422, 'unsupported_consent_version');
    }
    accepted.add(kind);
    missing = [
      for (final item in missing)
        if (item != kind) item,
    ];
    return _json(201, {
      'id': '00000000-0000-4000-8000-0000000000c1',
      'kind': kind,
      'version': body['version'],
      'source': 'in_app',
      'accepted_at': '2026-10-16T09:00:00Z',
      'withdrawn_at': null,
    });
  }

  http.Response _json(int status, Map<String, Object?> body) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );

  http.Response _error(int status, String code) => _json(status, {
        'error': {'code': code, 'message': 'synthetic'},
      });
}
