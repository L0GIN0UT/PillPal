import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pillpal/src/data/api/api_client.dart';
import 'package:pillpal/src/data/api/api_exception.dart';
import 'package:pillpal/src/data/api/auth_dto.dart';
import 'package:pillpal/src/data/auth/token_store.dart';
import 'package:pillpal/src/data/config.dart';

import 'test_env.dart';

Matcher _apiError(String code, int status) => isA<ApiException>()
    .having((e) => e.code, 'code', code)
    .having((e) => e.status, 'status', status);

void main() {
  late TestEnv env;

  setUp(() => env = TestEnv());
  tearDown(() => env.dispose());

  test('sends the device id and bearer token on every request', () async {
    await env.authApi.me();
    final request = env.server.requests.single;
    expect(request.headers['x-device-id'], await env.syncState.deviceId());
    expect(request.headers['authorization'], 'Bearer ${env.server.access}');
  });

  test('maps the error envelope to ApiException', () async {
    await expectLater(
      env.authApi.login(email: 'demo@example.com', password: 'wrong'),
      throwsA(_apiError('invalid_credentials', 401)),
    );
    await expectLater(
      env.authApi.login(email: 'demo@example.com', password: 'unverified-pass'),
      throwsA(_apiError('email_not_verified', 403)),
    );
  });

  test('a non-envelope error falls back to http_<status>', () async {
    final client = ApiClient(
      httpClient: MockClient(
        (request) async => http.Response('<html>bad gateway</html>', 502),
      ),
      config: ApiConfig(baseUrl: Uri.parse('http://api.test'), region: 'ru'),
      tokens: InMemoryTokenStore(),
      deviceId: () async => 'device-1',
    );
    await expectLater(
      client.post('/v1/auth/register', body: {}, authenticated: false),
      throwsA(_apiError('http_502', 502)),
    );
  });

  test('429 carries Retry-After', () async {
    final client = ApiClient(
      httpClient: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'error': {'code': 'rate_limited', 'message': 'Too many requests'},
          }),
          429,
          headers: {'retry-after': '42', 'content-type': 'application/json'},
        ),
      ),
      config: ApiConfig(baseUrl: Uri.parse('http://api.test'), region: 'ru'),
      tokens: InMemoryTokenStore(),
      deviceId: () async => 'device-1',
    );
    await expectLater(
      client.post('/v1/auth/login', body: {}, authenticated: false),
      throwsA(isA<ApiException>()
          .having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 42))),
    );
  });

  test('transport failures become network_error', () async {
    final client = ApiClient(
      httpClient: MockClient(
        (request) async => throw http.ClientException('offline'),
      ),
      config: ApiConfig(baseUrl: Uri.parse('http://api.test'), region: 'ru'),
      tokens: InMemoryTokenStore(),
      deviceId: () async => 'device-1',
    );
    await expectLater(
      client.get('/v1/me', authenticated: false),
      throwsA(_apiError(ApiException.networkError, 0)),
    );
  });

  test('decodes UTF-8 bodies without a charset', () async {
    final client = ApiClient(
      httpClient: MockClient(
        (request) async => http.Response.bytes(
          utf8.encode(jsonEncode({'name': 'Аспирин'})),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
      config: ApiConfig(baseUrl: Uri.parse('http://api.test/'), region: 'ru'),
      tokens: InMemoryTokenStore(),
      deviceId: () async => 'device-1',
    );
    final json = await client.get('/v1/x', authenticated: false);
    expect(json, {'name': 'Аспирин'});
  });

  test('signed out: authenticated calls fail without a request', () async {
    final signedOut = TestEnv(signedIn: false);
    addTearDown(signedOut.dispose);
    await expectLater(
      signedOut.authApi.me(),
      throwsA(_apiError(ApiException.unauthorized, 401)),
    );
    expect(signedOut.server.requests, isEmpty);
  });

  group('auth flow', () {
    late TestEnv fresh;

    setUp(() => fresh = TestEnv(signedIn: false));
    tearDown(() => fresh.dispose());

    test('register -> verify-email signs in; logout signs out', () async {
      await fresh.authApi.register(
        const RegisterRequest(
          email: 'demo@example.com',
          password: 'correct-pass',
          region: 'ru',
          locale: 'ru',
          timezone: 'Europe/Samara',
        ),
      );
      expect(await fresh.authApi.isSignedIn(), isFalse);
      await fresh.authApi.resendVerification('demo@example.com');
      await expectLater(
        fresh.authApi.verifyEmail(email: 'demo@example.com', code: '000000'),
        throwsA(_apiError('invalid_code', 400)),
      );
      await fresh.authApi.verifyEmail(email: 'demo@example.com', code: '123456');
      final tokens = (await fresh.tokens.read())!;
      expect(tokens.accessToken, fresh.server.access);
      expect(
        tokens.accessExpiresAt,
        fresh.clock.now.add(const Duration(seconds: 900)),
      );

      await fresh.authApi.logout();
      expect(await fresh.authApi.isSignedIn(), isFalse);
      final paths = [for (final r in fresh.server.requests) r.path];
      expect(paths, [
        '/v1/auth/register',
        '/v1/auth/verify-email/resend',
        '/v1/auth/verify-email',
        '/v1/auth/verify-email',
        '/v1/auth/logout',
      ]);
      expect(
        fresh.server.requests.last.body,
        {'refresh_token': tokens.refreshToken},
      );
      final register = fresh.server.requests.first.body! as Map<String, Object?>;
      expect(register.containsKey('display_name'), isFalse);
      expect(register['region'], 'ru');
    });

    test('login stores the token pair', () async {
      await fresh.authApi.login(email: 'demo@example.com', password: 'correct-pass');
      expect((await fresh.tokens.read())!.refreshToken, fresh.server.refresh);
    });
  });

  group('refresh on 401', () {
    test('refreshes once and retries the request', () async {
      env.server.expireAccess();
      final me = await env.authApi.me();
      expect(me.email, 'demo@example.com');
      expect(env.server.refreshCalls, 1);
      expect((await env.tokens.read())!.accessToken, env.server.access);
      expect(
        [for (final r in env.server.requests) r.path],
        ['/v1/me', '/v1/auth/refresh', '/v1/me'],
      );
    });

    test('concurrent 401s share a single refresh', () async {
      env.server.expireAccess();
      final gate = Completer<void>();
      env.server.refreshGate = gate;
      final calls = [for (var i = 0; i < 3; i++) env.authApi.me()];
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.complete();
      final results = await Future.wait(calls);
      expect(results, hasLength(3));
      expect(env.server.refreshCalls, 1);
    });

    test('a request that lost the race reuses the new tokens', () async {
      final stale = (await env.tokens.read())!;
      env.server.expireAccess();
      final fresh = TokenPair(
        accessToken: env.server.access,
        refreshToken: env.server.refresh,
        accessExpiresAt: env.clock.now.add(const Duration(minutes: 15)),
      );
      // The first read sees the stale pair; by the time the 401 arrives
      // another request has stored the refreshed one.
      final client = ApiClient(
        httpClient: env.server.client,
        config: ApiConfig(baseUrl: Uri.parse('http://api.test'), region: 'ru'),
        tokens: _SwitchingTokenStore(stale, fresh),
        deviceId: () async => 'device-1',
      );
      final me = await client.get('/v1/me');
      expect(me!['email'], 'demo@example.com');
      expect(env.server.refreshCalls, 0);
      expect(
        [for (final r in env.server.requests) r.headers['authorization']],
        ['Bearer ${stale.accessToken}', 'Bearer ${fresh.accessToken}'],
      );
    });

    test('a rejected refresh token signs out', () async {
      env.server.expireAccess();
      env.server.refresh = 'rotated-elsewhere';
      await expectLater(
        env.authApi.me(),
        throwsA(_apiError('token_reused', 401)),
      );
      expect(await env.tokens.read(), isNull);
    });
  });
}

/// Returns [first] on the first read and [then] afterwards.
class _SwitchingTokenStore implements TokenStore {
  _SwitchingTokenStore(this.first, this.then);

  final TokenPair first;
  final TokenPair then;
  int _reads = 0;

  @override
  Future<TokenPair?> read() async => _reads++ == 0 ? first : then;

  @override
  Future<void> write(TokenPair tokens) async {}

  @override
  Future<void> clear() async {}
}
