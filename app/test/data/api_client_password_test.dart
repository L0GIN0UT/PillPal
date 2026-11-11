import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pillpal/src/data/api/api_client.dart';
import 'package:pillpal/src/data/api/api_exception.dart';
import 'package:pillpal/src/data/api/auth_api.dart';
import 'package:pillpal/src/data/api/auth_dto.dart';
import 'package:pillpal/src/data/auth/token_store.dart';
import 'package:pillpal/src/data/config.dart';

import '../helpers.dart';

http.Response _json(int status, Object body) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

http.Response _error(int status, String code) => _json(status, {
      'error': {'code': code, 'message': 'synthetic'},
    });

TokenPair _pair(String access, String refresh) => TokenPair(
      accessToken: access,
      refreshToken: refresh,
      accessExpiresAt: DateTime.utc(2100),
    );

ApiClient _client(
  Future<http.Response> Function(http.Request request) handler,
  InMemoryTokenStore tokens,
) =>
    ApiClient(
      httpClient: MockClient(handler),
      config: ApiConfig(baseUrl: Uri.parse('https://api.test'), region: 'ru'),
      tokens: tokens,
      deviceId: () async => 'device-1',
    );

void main() {
  test(
    'a wrong current password on the change request does not refresh',
    () async {
      final paths = <String>[];
      final tokens = InMemoryTokenStore(_pair('access', 'refresh'));
      final api = AuthApi(
        _client((request) async {
          paths.add('${request.method} ${request.url.path}');
          return _error(401, 'invalid_password');
        }, tokens),
        tokens,
      );

      await expectLater(
        api.requestPasswordChange('wrong'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'invalid_password')
              .having((e) => e.status, 'status', 401),
        ),
      );
      expect(paths, ['POST /v1/auth/password-change/request']);
      expect((await tokens.read())!.refreshToken, 'refresh');
    },
  );

  test(
    'the 401 after a changed password refreshes and keeps the tokens',
    () async {
      // The server kills the old access token (password_changed_at) but not
      // the refresh token of this session.
      final seen = <String>[];
      final newAccess = fakeAccessToken();
      final tokens = InMemoryTokenStore(_pair('old-access', 'refresh-1'));
      final api = AuthApi(
        _client((request) async {
          seen.add(
            '${request.method} ${request.url.path} '
            '${request.headers['authorization'] ?? ''}',
          );
          switch (request.url.path) {
            case '/v1/auth/password-change/confirm':
              return http.Response('', 204);
            case '/v1/auth/refresh':
              return _json(200, {
                'access_token': newAccess,
                'refresh_token': 'refresh-2',
                'expires_in': 900,
              });
            default:
              return request.headers['authorization'] == 'Bearer $newAccess'
                  ? _json(200, {
                      'id': 'user-1',
                      'email': 'user@example.test',
                      'email_verified': true,
                      'has_password': true,
                      'region': 'ru',
                      'locale': 'ru',
                    })
                  : _error(401, 'invalid_token');
          }
        }, tokens),
        tokens,
      );

      await api.confirmPasswordChange(
        code: '123456',
        newPassword: 'a-new-long-password',
      );
      // Confirming does not touch the tokens.
      expect((await tokens.read())!.accessToken, 'old-access');

      final me = await api.me();

      expect(me.hasPassword, isTrue);
      expect(seen, [
        'POST /v1/auth/password-change/confirm Bearer old-access',
        'GET /v1/me Bearer old-access',
        'POST /v1/auth/refresh ',
        'GET /v1/me Bearer $newAccess',
      ]);
      final stored = (await tokens.read())!;
      expect(stored.accessToken, newAccess);
      expect(stored.refreshToken, 'refresh-2');
    },
  );

  test('the change bodies carry only the schema fields', () async {
    final bodies = <Map<String, Object?>>[];
    final tokens = InMemoryTokenStore(_pair('access', 'refresh'));
    final api = AuthApi(
      _client((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, Object?>);
        return http.Response(
          '',
          request.url.path.endsWith('request') ? 202 : 204,
        );
      }, tokens),
      tokens,
    );

    await api.requestPasswordChange('current-pass');
    await api.confirmPasswordChange(
      code: '123456',
      newPassword: 'new-password',
    );

    expect(bodies, [
      {'current_password': 'current-pass'},
      {'code': '123456', 'new_password': 'new-password'},
    ]);
  });

  test('a wrong password on an authenticated call does not refresh', () async {
    // 401 `invalid_password` answers a live session (DELETE /v1/me): the
    // access token is fine, so no refresh token is rotated for it.
    final paths = <String>[];
    final client = ApiClient(
      httpClient: MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        return http.Response(
          jsonEncode({
            'error': {'code': 'invalid_password', 'message': 'synthetic'},
          }),
          401,
          headers: {'content-type': 'application/json'},
        );
      }),
      config: ApiConfig(baseUrl: Uri.parse('https://api.test'), region: 'ru'),
      tokens: InMemoryTokenStore(
        TokenPair(
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: DateTime.utc(2100),
        ),
      ),
      deviceId: () async => 'device-1',
    );

    await expectLater(
      client.delete('/v1/me', body: {'password': 'wrong'}),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', 'invalid_password')
            .having((e) => e.status, 'status', 401),
      ),
    );
    expect(paths, ['DELETE /v1/me']);
  });
}
