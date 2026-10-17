import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../auth/access_claims.dart';
import '../auth/token_store.dart';
import '../clock.dart';
import '../config.dart';
import '../sync/sync_lease.dart';
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
/// the request once. A rejected refresh token only forgets the tokens: the
/// local data stays bound to its account, so signing in again as the same
/// account pushes the pending outbox (another account erases it, see
/// [SessionListener]). Requests made for an account's data ([forUser]) are
/// never sent with another account's token - checked before the request and
/// before the retry after a refresh. Every response's `Date` header feeds the
/// [ServerClock].
///
/// With a [SyncLease] the refresh is the lease holder's work (ADR 0001,
/// addendum 3.7): isolates never rotate the refresh token at the same time,
/// the tokens are re-read once the lease is had (another isolate may have
/// refreshed meanwhile), and a holder whose lease lapsed during the request
/// neither stores nor forgets tokens - it adopts whatever the new holder
/// stored. Without a lease, concurrent requests of this client share one
/// refresh.
class ApiClient {
  /// Creates a client.
  ApiClient({
    required http.Client httpClient,
    required ApiConfig config,
    required TokenStore tokens,
    required DeviceIdSource deviceId,
    ServerClock? serverClock,
    SessionListener? session,
    SyncLease? lease,
    bool refreshEnabled = true,
  })  : _http = httpClient,
        _config = config,
        _tokens = tokens,
        _deviceId = deviceId,
        _serverClock = serverClock ?? ServerClock(),
        _session = session,
        _lease = lease,
        _refreshEnabled = refreshEnabled;

  final http.Client _http;
  final ApiConfig _config;
  final TokenStore _tokens;
  final DeviceIdSource _deviceId;
  final ServerClock _serverClock;
  final SessionListener? _session;
  final SyncLease? _lease;
  final bool _refreshEnabled;
  Future<TokenPair>? _refreshing;

  /// The data region of the configured server.
  String get region => _config.region;

  /// Forgets the session and its local data (explicit logout).
  ///
  /// Under the sync lease, so no refresh is in flight that could store tokens
  /// after the sign-out; if the lease stays busy the sign-out goes on anyway
  /// (the user's wish wins). The binding is dropped before the tokens are
  /// cleared, so a background refresh that still lands refuses to store
  /// tokens for an unbound account.
  Future<void> signOutLocally() async {
    final lease = _lease;
    if (lease == null) {
      await _forgetSession();
      return;
    }
    try {
      await lease.run((grant) => _forgetSession());
    } on LeaseBusy {
      await _forgetSession();
    }
  }

  Future<void> _forgetSession() async {
    await _session?.signedOut();
    await _tokens.clear();
  }

  /// POSTs [body]; returns the decoded object, or null for an empty body.
  /// With [forUser], the stored token must belong to that account.
  Future<JsonMap?> post(
    String path, {
    JsonMap? body,
    bool authenticated = true,
    String? forUser,
  }) =>
      _send('POST', _config.resolve(path), body, authenticated, forUser);

  /// GETs [path] with [query]; [forUser] as in [post].
  Future<JsonMap?> get(
    String path, {
    Map<String, String>? query,
    bool authenticated = true,
    String? forUser,
  }) =>
      _send('GET', _config.resolve(path, query), null, authenticated, forUser);

  Future<JsonMap?> _send(
    String method,
    Uri uri,
    JsonMap? body,
    bool authenticated,
    String? forUser,
  ) async {
    if (!authenticated) {
      return _decode(await _raw(method, uri, body, null));
    }
    final tokens = await _tokens.read();
    if (tokens == null) {
      throw const ApiException(ApiException.unauthorized, 401);
    }
    _checkAccount(tokens, forUser);
    var response = await _raw(method, uri, body, tokens.accessToken);
    if (response.statusCode == 401) {
      final fresh = await _refreshAfter(tokens.accessToken);
      _checkAccount(fresh, forUser);
      response = await _raw(method, uri, body, fresh.accessToken);
    }
    return _decode(response);
  }

  void _checkAccount(TokenPair tokens, String? forUser) {
    if (forUser != null &&
        AccessClaims.fromToken(tokens.accessToken)?.userId != forUser) {
      throw const ApiException(ApiException.accountChanged, 0);
    }
  }

  /// Tokens newer than [rejectedAccess], refreshing at most once at a time.
  Future<TokenPair> _refreshAfter(String rejectedAccess) async {
    if (!_refreshEnabled) {
      throw const ApiException(ApiException.refreshDeferred, 0);
    }
    final lease = _lease;
    if (lease != null) {
      return _refreshUnderLease(lease, rejectedAccess);
    }
    final current = await _tokens.read();
    if (current == null) {
      throw const ApiException(ApiException.unauthorized, 401);
    }
    if (current.accessToken != rejectedAccess) {
      return current; // another request already refreshed the session
    }
    return _refreshing ??= _rotate(current.refreshToken, () async => true)
        .then(saveTokens)
        .whenComplete(() => _refreshing = null);
  }

  Future<TokenPair> _refreshUnderLease(
    SyncLease lease,
    String rejectedAccess,
  ) async {
    try {
      return await lease.run(
        (grant) => _refreshHolding(lease, grant, rejectedAccess),
      );
    } on LeaseBusy {
      throw const ApiException(ApiException.syncBusy, 0);
    } on LeaseLost {
      throw const ApiException(ApiException.leaseLost, 0);
    }
  }

  /// The refresh of the lease holder. The tokens are read only now: whoever
  /// held the lease before may have refreshed already.
  Future<TokenPair> _refreshHolding(
    SyncLease lease,
    LeaseGrant grant,
    String rejectedAccess,
  ) async {
    final current = await _tokens.read();
    if (current == null) {
      throw const ApiException(ApiException.unauthorized, 401);
    }
    if (current.accessToken != rejectedAccess) {
      return current;
    }
    await lease.ensure(grant);
    final json = await _rotate(
      current.refreshToken,
      // A stale holder must not forget tokens the new holder may have
      // stored (or is about to).
      () => lease.holds(grant),
    );
    try {
      await lease.ensure(grant); // fencing, and a fresh TTL for the write
    } on LeaseLost {
      final latest = await _tokens.read();
      if (latest != null && latest.accessToken != rejectedAccess) {
        return latest;
      }
      throw const ApiException(ApiException.leaseLost, 0);
    }
    return saveTokens(json);
  }

  /// POSTs the rotation; a rejected token is forgotten when [mayForget].
  Future<JsonMap?> _rotate(
    String refreshToken,
    Future<bool> Function() mayForget,
  ) async {
    try {
      return await post(
        '/v1/auth/refresh',
        body: AuthBodies.refresh(refreshToken),
        authenticated: false,
      );
    } on ApiException catch (error) {
      if (error.isUnauthorized && await mayForget()) {
        // Invalid, expired or reused: forget the tokens, keep the data bound
        // to its account (re-login as the same account pushes the outbox).
        await _tokens.clear();
      }
      rethrow;
    }
  }

  /// Stores tokens returned by verify-email, login or refresh.
  ///
  /// The [SessionListener] runs first, so local data of another account is
  /// erased before these tokens could be used to push it.
  Future<TokenPair> saveTokens(JsonMap? json) async {
    final tokens = TokenPair.fromJson(_require(json), _serverClock.deviceNow());
    final claims = AccessClaims.fromToken(tokens.accessToken);
    if (claims == null) {
      throw const ApiException(ApiException.invalidResponse, 200);
    }
    await _session?.signingIn(claims);
    await _tokens.write(tokens);
    return tokens;
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
      final response = await http.Response.fromStream(streamed)
          .timeout(_config.requestTimeout);
      _observeDate(response);
      return response;
    } on http.ClientException {
      throw const ApiException(ApiException.networkError, 0);
    } on TimeoutException {
      throw const ApiException(ApiException.networkError, 0);
    } on IOException {
      // Sockets, TLS handshakes (HandshakeException), HTTP framing.
      throw const ApiException(ApiException.networkError, 0);
    }
  }

  void _observeDate(http.Response response) {
    final header = response.headers['date'];
    if (header == null) {
      return;
    }
    try {
      _serverClock.observe(HttpDate.parse(header), _serverClock.deviceNow());
    } on HttpException {
      // Malformed Date: keep the previous estimate.
    } on FormatException {
      // Same.
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
    final error = _errorBody(response);
    final details = error?['details'];
    final code = error?['code'];
    throw ApiException(
      code is String ? code : 'http_$status',
      status,
      retryAfter: _retryAfter(response),
      details: details is Map<String, Object?> ? details : null,
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

  /// The `error` object of the envelope `{"error": {"code", ...}}`.
  Map<String, Object?>? _errorBody(http.Response response) {
    try {
      final Object? json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is Map<String, Object?>) {
        final error = json['error'];
        if (error is Map<String, Object?>) {
          return error;
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
