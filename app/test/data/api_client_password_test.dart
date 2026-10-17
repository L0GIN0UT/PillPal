import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pillpal/src/data/api/api_client.dart';
import 'package:pillpal/src/data/api/api_exception.dart';
import 'package:pillpal/src/data/api/auth_dto.dart';
import 'package:pillpal/src/data/auth/token_store.dart';
import 'package:pillpal/src/data/config.dart';

void main() {
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
