import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pillpal/src/data/api/api_client.dart';
import 'package:pillpal/src/data/api/api_exception.dart';
import 'package:pillpal/src/data/api/auth_dto.dart';
import 'package:pillpal/src/data/auth/token_store.dart';
import 'package:pillpal/src/data/config.dart';

// ApiClient.downloadTo (the export archive): streamed to a file, one retry
// after a 401 only (auth fails before the server claims the archive), a single
// attempt for everything after the headers, and no partial file on any
// failure (ADR 0016 §8; privacy rule 1: nothing here may name the file).

const String _user = 'user-1';
const String _path = '/v1/me/export/00000000-0000-4000-8000-0000000000e1/'
    'download';

String _jwt(int serial) {
  String part(Map<String, Object?> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.'
      '${part({'sub': _user, 'region': 'ru', 'n': serial})}.signature';
}

TokenPair _pair(int serial) => TokenPair(
      accessToken: _jwt(serial),
      refreshToken: 'refresh-$serial',
      accessExpiresAt: DateTime.utc(2100),
    );

http.StreamedResponse _bytes(
  List<int> body, {
  int status = 200,
  int? contentLength,
}) =>
    http.StreamedResponse(
      Stream.value(body),
      status,
      contentLength: contentLength ?? body.length,
    );

http.StreamedResponse _error(int status, String code) {
  final body = utf8.encode(
    jsonEncode({
      'error': {'code': code, 'message': 'synthetic'},
    }),
  );
  return http.StreamedResponse(
    Stream.value(body),
    status,
    contentLength: body.length,
  );
}

http.StreamedResponse _refreshed(int serial) {
  final body = utf8.encode(
    jsonEncode({
      'access_token': _jwt(serial),
      'refresh_token': 'refresh-$serial',
      'token_type': 'bearer',
      'expires_in': 900,
    }),
  );
  return http.StreamedResponse(Stream.value(body), 200);
}

void main() {
  late Directory dir;
  late File target;
  late List<http.BaseRequest> sent;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pillpal-download-');
    target = File('${dir.path}/exports/archive.zip');
    sent = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  ApiClient client(
    Future<http.StreamedResponse> Function(http.BaseRequest request) handler, {
    TokenPair? tokens,
    Duration timeout = const Duration(seconds: 30),
  }) =>
      ApiClient(
        httpClient: MockClient.streaming((request, _) async {
          sent.add(request);
          return handler(request);
        }),
        config: ApiConfig(
          baseUrl: Uri.parse('https://api.test'),
          region: 'ru',
          requestTimeout: timeout,
        ),
        tokens: InMemoryTokenStore(tokens ?? _pair(1)),
        deviceId: () async => 'device-1',
      );

  Future<void> download(ApiClient api, {int maxBytes = 1024}) =>
      api.downloadTo(_path, target, maxBytes: maxBytes, forUser: _user);

  test('streams the archive into the file, as a POST asking for a zip',
      () async {
    final api = client((_) async => _bytes([1, 2, 3, 4]));

    await download(api);

    expect(await target.readAsBytes(), [1, 2, 3, 4]);
    expect(sent, hasLength(1));
    expect(sent.single.method, 'POST');
    expect(sent.single.url.path, _path);
    expect(sent.single.headers['Accept'], 'application/zip');
    expect(sent.single.headers['Authorization'], 'Bearer ${_jwt(1)}');
    expect(sent.single.headers['X-Device-ID'], 'device-1');
  });

  test('a 401 refreshes the session and retries exactly once', () async {
    final api = client((request) async {
      if (request.url.path == '/v1/auth/refresh') {
        return _refreshed(2);
      }
      return request.headers['Authorization'] == 'Bearer ${_jwt(2)}'
          ? _bytes([9, 9])
          : _error(401, 'invalid_token');
    });

    await download(api);

    expect(await target.readAsBytes(), [9, 9]);
    expect(
      [for (final request in sent) request.url.path],
      [_path, '/v1/auth/refresh', _path],
    );
    expect(sent.last.headers['Authorization'], 'Bearer ${_jwt(2)}');
  });

  test('a second 401 is the answer: no third attempt, no file', () async {
    final api = client((request) async {
      return request.url.path == '/v1/auth/refresh'
          ? _refreshed(2)
          : _error(401, 'invalid_token');
    });

    await expectLater(
      download(api),
      throwsA(isA<ApiException>().having((e) => e.isUnauthorized, '401', true)),
    );

    expect(sent.where((r) => r.url.path == _path), hasLength(2));
    expect(target.existsSync(), isFalse);
  });

  test('a rejected refresh token ends the download with that 401', () async {
    final api = client((request) async => _error(401, 'token_reused'));

    await expectLater(
      download(api),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
    );

    expect(target.existsSync(), isFalse);
  });

  test('410 export_gone is its code, with no file', () async {
    final api = client((_) async => _error(410, 'export_gone'));

    await expectLater(
      download(api),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', 'export_gone')
            .having((e) => e.status, 'status', 410),
      ),
    );

    expect(target.existsSync(), isFalse);
    expect(sent, hasLength(1));
  });

  test('a 2xx that is not the archive is an invalid response', () async {
    final api = client((_) async => _bytes([], status: 204, contentLength: 0));

    await expectLater(
      download(api),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', ApiException.invalidResponse),
      ),
    );

    expect(target.existsSync(), isFalse);
  });

  test('a connection that breaks mid-stream deletes the partial file and is '
      'not repeated', () async {
    final api = client((_) async {
      final body = StreamController<List<int>>();
      body.add([1, 2, 3]);
      scheduleMicrotask(() {
        body.addError(http.ClientException('connection closed'));
        unawaited(body.close());
      });
      return http.StreamedResponse(body.stream, 200);
    });

    await expectLater(
      download(api),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', ApiException.networkError),
      ),
    );

    expect(target.existsSync(), isFalse);
    expect(sent, hasLength(1), reason: 'the archive is claimed: no retry');
  });

  test('a network error before any response is not retried either', () async {
    final api = client((_) async => throw http.ClientException('offline'));

    await expectLater(
      download(api),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', ApiException.networkError),
      ),
    );

    expect(sent, hasLength(1));
    expect(target.existsSync(), isFalse);
  });

  test('a body shorter than announced is a failed transfer', () async {
    final api = client((_) async => _bytes([1, 2, 3], contentLength: 10));

    await expectLater(
      download(api),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', ApiException.networkError),
      ),
    );

    expect(target.existsSync(), isFalse);
  });

  test('a stalled stream times out and deletes the partial file', () async {
    final api = client(
      (_) async {
        final body = StreamController<List<int>>()..add([1, 2, 3]);
        addTearDown(body.close);
        return http.StreamedResponse(body.stream, 200);
      },
      timeout: const Duration(milliseconds: 50),
    );

    await expectLater(
      download(api),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', ApiException.networkError),
      ),
    );

    expect(target.existsSync(), isFalse);
  });

  group('size cap', () {
    test('an announced size over the cap is refused before any byte is '
        'written', () async {
      final api = client((_) async => _bytes([1], contentLength: 5000));

      await expectLater(
        download(api, maxBytes: 100),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', ApiException.responseTooLarge),
        ),
      );

      expect(target.existsSync(), isFalse);
    });

    test('a body that outgrows the cap while streaming is deleted', () async {
      final api = client((_) async {
        final body = StreamController<List<int>>()
          ..add(List.filled(60, 1))
          ..add(List.filled(60, 1));
        unawaited(body.close());
        // No announced length: the chunks are counted.
        return http.StreamedResponse(body.stream, 200);
      });

      await expectLater(
        download(api, maxBytes: 100),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', ApiException.responseTooLarge),
        ),
      );

      expect(target.existsSync(), isFalse);
    });

    test('exactly the cap is accepted', () async {
      final api = client((_) async => _bytes(List.filled(100, 7)));

      await download(api, maxBytes: 100);

      expect(target.lengthSync(), 100);
    });
  });

  test('a file that cannot be written is a storage error, not a network one',
      () async {
    // The "folder" of the target is a file.
    File('${dir.path}/exports').writeAsStringSync('in the way');
    final api = client((_) async => _bytes([1, 2, 3]));

    await expectLater(
      download(api),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', ApiException.storageError),
      ),
    );
  });

  test('a session of another account is refused before any request',
      () async {
    final api = client((_) async => _bytes([1]));

    await expectLater(
      api.downloadTo(_path, target, maxBytes: 10, forUser: 'someone-else'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', ApiException.accountChanged),
      ),
    );

    expect(sent, isEmpty);
  });

  test('without a session there is nothing to send', () async {
    final api = ApiClient(
      httpClient: MockClient.streaming((request, _) async {
        sent.add(request);
        return _bytes([1]);
      }),
      config: ApiConfig(baseUrl: Uri.parse('https://api.test'), region: 'ru'),
      tokens: InMemoryTokenStore(),
      deviceId: () async => 'device-1',
    );

    await expectLater(
      download(api),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
    );

    expect(sent, isEmpty);
  });

  test('errors never carry the file path', () async {
    final api = client((_) async => _bytes([1], contentLength: 5000));

    try {
      await download(api, maxBytes: 100);
      fail('expected an error');
    } on ApiException catch (error) {
      expect(error.toString(), isNot(contains(dir.path)));
      expect(error.toString(), isNot(contains('archive.zip')));
    }
  });
}
