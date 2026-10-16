import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/token_store.dart';
import '../clock.dart';
import '../config.dart';
import 'api_exception.dart';
import 'auth_dto.dart';
import 'json.dart';

/// Supplies the stable device id sent as `X-Device-ID`.
typedef DeviceIdSource = Future<String> Function();

/// HTTP transport for the PillPal API.
///
/// Adds `X-Device-ID` and the bearer token, maps the error envelope
/// `{"error": {"code", "message"}}` to [ApiException], and on a 401 refreshes
/// the session once (single flight shared by concurrent requests) and retries
/// the request once. A rejected refresh token signs the user out.
class ApiClient {
  /// Creates a client.
  ApiClient({
    required http.Client httpClient,
    required ApiConfig config,
    required TokenStore tokens,
    required DeviceIdSource deviceId,
    Clock clock = systemClock,
  })  : _http = httpClient,
        _config = config,
        _tokens = tokens,
        _deviceId = deviceId,
        _clock = clock;

  final http.Client _http;
  final ApiConfig _config;
  final TokenStore _tokens;
  final DeviceIdSource _deviceId;
  final Clock _clock;
  Future<TokenPair>? _refreshing;

  /// The data region of the configured server.
  String get region => _config.region;

  /// The current client time (for token expiry bookkeeping).
  DateTime now() => _clock();

  /// POSTs [body]; returns the decoded object, or null for an empty body.
  Future<JsonMap?> post(
    String path, {
    JsonMap? body,
    bool authenticated = true,
  }) =>
      _send('POST', _config.resolve(path), body, authenticated);

  /// GETs [path] with [query].
  Future<JsonMap?> get(
    String path, {
    Map<String, String>? query,
    bool authenticated = true,
  }) =>
      _send('GET', _config.resolve(path, query), null, authenticated);

  Future<JsonMap?> _send(
    String method,
    Uri uri,
    JsonMap? body,
    bool authenticated,
  ) async {
    if (!authenticated) {
      return _decode(await _raw(method, uri, body, null));
    }
    final tokens = await _tokens.read();
    if (tokens == null) {
      throw const ApiException(ApiException.unauthorized, 401);
    }
    var response = await _raw(method, uri, body, tokens.accessToken);
    if (response.statusCode == 401) {
      final fresh = await _refreshAfter(tokens.accessToken);
      response = await _raw(method, uri, body, fresh.accessToken);
    }
    return _decode(response);
  }

  /// Tokens newer than [rejectedAccess], refreshing at most once at a time.
  Future<TokenPair> _refreshAfter(String rejectedAccess) async {
    final current = await _tokens.read();
    if (current == null) {
      throw const ApiException(ApiException.unauthorized, 401);
    }
    if (current.accessToken != rejectedAccess) {
      return current; // another request already refreshed the session
    }
    return _refreshing ??=
        _refresh(current.refreshToken).whenComplete(() => _refreshing = null);
  }

  Future<TokenPair> _refresh(String refreshToken) async {
    final JsonMap? json;
    try {
      json = await post(
        '/v1/auth/refresh',
        body: AuthBodies.refresh(refreshToken),
        authenticated: false,
      );
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await _tokens.clear(); // invalid, expired or reused: sign out
      }
      rethrow;
    }
    final tokens = TokenPair.fromJson(_require(json), _clock());
    await _tokens.write(tokens);
    return tokens;
  }

  /// Stores tokens returned by verify-email or login.
  Future<void> saveTokens(JsonMap? json) async {
    await _tokens.write(TokenPair.fromJson(_require(json), _clock()));
  }

  Future<http.Response> _raw(
    String method,
    Uri uri,
    JsonMap? body,
    String? accessToken,
  ) async {
    final request = http.Request(method, uri)
      ..headers['Accept'] = 'application/json'
      ..headers['X-Device-ID'] = await _deviceId();
    if (accessToken != null) {
      request.headers['Authorization'] = 'Bearer $accessToken';
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.bodyBytes = utf8.encode(jsonEncode(body));
    }
    try {
      final streamed =
          await _http.send(request).timeout(_config.requestTimeout);
      return await http.Response.fromStream(streamed)
          .timeout(_config.requestTimeout);
    } on http.ClientException {
      throw const ApiException(ApiException.networkError, 0);
    } on TimeoutException {
      throw const ApiException(ApiException.networkError, 0);
    }
  }

  JsonMap? _decode(http.Response response) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      if (response.bodyBytes.isEmpty) {
        return null;
      }
      return asJsonMap(_parse(response), 'response');
    }
    throw ApiException(
      _errorCode(response) ?? 'http_$status',
      status,
      retryAfter: _retryAfter(response),
    );
  }

  Object? _parse(http.Response response) {
    try {
      // FastAPI sends application/json without a charset; JSON is UTF-8.
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw ApiException(ApiException.invalidResponse, response.statusCode);
    }
  }

  String? _errorCode(http.Response response) {
    try {
      final Object? json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is Map<String, Object?>) {
        final error = json['error'];
        if (error is Map<String, Object?>) {
          final code = error['code'];
          return code is String ? code : null;
        }
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  Duration? _retryAfter(http.Response response) {
    final seconds = int.tryParse(response.headers['retry-after'] ?? '');
    return seconds == null ? null : Duration(seconds: seconds);
  }

  JsonMap _require(JsonMap? json) {
    if (json == null) {
      throw const ApiException(ApiException.invalidResponse, 200);
    }
    return json;
  }
}
