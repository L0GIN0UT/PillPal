import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pillpal/src/data/api/api_client.dart';
import 'package:pillpal/src/data/api/api_exception.dart';
import 'package:pillpal/src/data/api/auth_api.dart';
import 'package:pillpal/src/data/auth/token_store.dart';
import 'package:pillpal/src/data/config.dart';

http.Response _error(int status, String code) => http.Response(
      jsonEncode({
        'error': {'code': code, 'message': 'synthetic'},
      }),
      status,
      headers: {'content-type': 'application/json'},
    );

/// An [AuthApi] over a fake HTTP client that records `METHOD path` and body.
AuthApi _api(
  List<(String, Map<String, Object?>)> sent,
  http.Response Function() answer,
) {
  final client = ApiClient(
    httpClient: MockClient((request) async {
      sent.add((
        '${request.method} ${request.url.path}',
        Map<String, Object?>.from(jsonDecode(request.body) as Map),
      ));
      return answer();
    }),
    config: ApiConfig(baseUrl: Uri.parse('https://api.test'), region: 'ru'),
    tokens: InMemoryTokenStore(null),
    deviceId: () async => 'device-1',
  );
  return AuthApi(client, InMemoryTokenStore(null));
}

void main() {
  test('requestPasswordReset posts the address and accepts 202', () async {
    final sent = <(String, Map<String, Object?>)>[];
    final api = _api(sent, () => http.Response('', 202));

    await api.requestPasswordReset('user@example.test');

    expect(sent.map((r) => r.$1), ['POST /v1/auth/password-reset/request']);
    expect(sent.single.$2, {'email': 'user@example.test'});
  });

  test('confirmPasswordReset posts address, code and new password (204)',
      () async {
    final sent = <(String, Map<String, Object?>)>[];
    final api = _api(sent, () => http.Response('', 204));

    await api.confirmPasswordReset(
      email: 'user@example.test',
      code: '123456',
      newPassword: 'a-new-long-password',
    );

    expect(sent.map((r) => r.$1), ['POST /v1/auth/password-reset/confirm']);
    expect(sent.single.$2, {
      'email': 'user@example.test',
      'code': '123456',
      'new_password': 'a-new-long-password',
    });
  });

  test('confirmPasswordReset does not sign in (no tokens are stored)',
      () async {
    final tokens = InMemoryTokenStore(null);
    final client = ApiClient(
      httpClient: MockClient((_) async => http.Response('', 204)),
      config: ApiConfig(baseUrl: Uri.parse('https://api.test'), region: 'ru'),
      tokens: tokens,
      deviceId: () async => 'device-1',
    );
    await AuthApi(client, tokens).confirmPasswordReset(
      email: 'user@example.test',
      code: '123456',
      newPassword: 'a-new-long-password',
    );
    expect(await tokens.read(), isNull);
  });

  for (final (status, code) in [
    (400, 'invalid_code'),
    (422, 'validation_error'),
    (429, 'rate_limited'),
  ]) {
    test('confirmPasswordReset surfaces $status $code', () async {
      final api = _api([], () => _error(status, code));
      await expectLater(
        api.confirmPasswordReset(
          email: 'user@example.test',
          code: '123456',
          newPassword: 'a-new-long-password',
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', code)
              .having((e) => e.status, 'status', status),
        ),
      );
    });
  }

  test('requestPasswordReset surfaces 429 rate_limited', () async {
    final api = _api([], () => _error(429, 'rate_limited'));
    await expectLater(
      api.requestPasswordReset('user@example.test'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'rate_limited'),
      ),
    );
  });
}
