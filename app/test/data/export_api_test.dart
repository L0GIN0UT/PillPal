import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pillpal/src/data/api/api_client.dart';
import 'package:pillpal/src/data/api/api_exception.dart';
import 'package:pillpal/src/data/api/auth_dto.dart';
import 'package:pillpal/src/data/api/export_api.dart';
import 'package:pillpal/src/data/api/export_dto.dart';
import 'package:pillpal/src/data/auth/token_store.dart';
import 'package:pillpal/src/data/config.dart';

import '../helpers.dart';

// The export endpoints (ADR 0016 §8, docs/spec/export.md).

const String _id = '00000000-0000-4000-8000-0000000000e1';

Map<String, Object?> _export(String status, {Map<String, Object?>? extra}) => {
      'id': _id,
      'status': status,
      'requested_at': '2026-11-11T08:00:00Z',
      ...?extra,
    };

http.Response _json(int status, Object body, {Map<String, String>? headers}) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json', ...?headers},
    );

http.Response _error(int status, String code, {Map<String, String>? headers}) =>
    _json(
      status,
      {
        'error': {'code': code, 'message': 'synthetic'},
      },
      headers: headers,
    );

void main() {
  late List<http.Request> sent;

  ExportApi api(Future<http.Response> Function(http.Request request) handler) {
    sent = [];
    final client = ApiClient(
      httpClient: MockClient((request) async {
        sent.add(request);
        return handler(request);
      }),
      config: ApiConfig(baseUrl: Uri.parse('https://api.test'), region: 'ru'),
      tokens: InMemoryTokenStore(
        TokenPair(
          accessToken: fakeAccessToken(),
          refreshToken: 'refresh',
          accessExpiresAt: DateTime.utc(2100),
        ),
      ),
      deviceId: () async => 'device-1',
    );
    return ExportApi(client);
  }

  group('DataExport', () {
    test('reads the status and the optional fields', () {
      final export = DataExport.fromJson(
        _export(
          'ready',
          extra: {
            'ready_at': '2026-11-11T08:01:00Z',
            'expires_at': '2026-11-12T08:01:00Z',
            'size_bytes': 2048,
          },
        ),
      );

      expect(export.id, _id);
      expect(export.status, ExportStatus.ready);
      expect(export.readyAt, DateTime.utc(2026, 11, 11, 8, 1));
      expect(export.sizeBytes, 2048);
      expect(export.errorCode, isNull);
    });

    test('a failed export carries its error code', () {
      final export = DataExport.fromJson(
        _export('failed', extra: {'error_code': 'export_too_large'}),
      );

      expect(export.status, ExportStatus.failed);
      expect(export.errorCode, ExportErrors.tooLarge);
    });

    test('a status the app does not know is a format error', () {
      expect(
        () => DataExport.fromJson(_export('teleporting')),
        throwsFormatException,
      );
    });

    test('an id that is not a UUID never reaches a request path', () {
      expect(
        () => DataExport.fromJson({..._export('queued'), 'id': '../../me'}),
        throwsFormatException,
      );
    });
  });

  group('request', () {
    test('POSTs the password and reads the new export (202)', () async {
      final export = await api((_) async => _json(202, _export('queued')))
          .request('synthetic-pass', userId: 'user-1');

      expect(export.status, ExportStatus.queued);
      expect(sent.single.method, 'POST');
      expect(sent.single.url.path, '/v1/me/export');
      expect(jsonDecode(sent.single.body), {'password': 'synthetic-pass'});
    });

    test('a replay (200) is the same export', () async {
      final export = await api((_) async => _json(200, _export('running')))
          .request('synthetic-pass', userId: 'user-1');

      expect(export.id, _id);
      expect(export.status, ExportStatus.running);
    });

    test('a wrong password is its code and spends no refresh', () async {
      final exports = api((_) async => _error(401, 'invalid_password'));

      await expectLater(
        exports.request('wrong', userId: 'user-1'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'invalid_password')
              .having((e) => e.status, 'status', 401),
        ),
      );

      expect([for (final r in sent) r.url.path], ['/v1/me/export']);
    });

    test('the cooldown is a 429 with the wait the server asks for', () async {
      final exports = api(
        (_) async => _error(
          429,
          ExportErrors.rateLimited,
          headers: {'retry-after': '1800'},
        ),
      );

      await expectLater(
        exports.request('synthetic-pass', userId: 'user-1'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', ExportErrors.rateLimited)
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(minutes: 30),
              ),
        ),
      );
    });

    test('the flag being off is 403 feature_disabled', () async {
      final exports = api((_) async => _error(403, 'feature_disabled'));

      await expectLater(
        exports.request('synthetic-pass', userId: 'user-1'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', ExportErrors.featureDisabled),
        ),
      );
    });

    test('refuses to run for an account that is not the signed-in one',
        () async {
      final exports = api((_) async => _json(202, _export('queued')));

      await expectLater(
        exports.request('synthetic-pass', userId: 'someone-else'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', ApiException.accountChanged),
        ),
      );

      expect(sent, isEmpty);
    });
  });

  test('status GETs the export by id', () async {
    final export = await api((_) async => _json(200, _export('queued')))
        .status(_id, userId: 'user-1');

    expect(export.status, ExportStatus.queued);
    expect(sent.single.method, 'GET');
    expect(sent.single.url.path, '/v1/me/export/$_id');
  });

  test('download POSTs to the download path and writes the file', () async {
    final dir = Directory.systemTemp.createTempSync('pillpal-export-api-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/a.zip');
    final exports = api(
      (_) async => http.Response.bytes(
        [80, 75, 3, 4],
        200,
        headers: {'content-type': 'application/zip'},
      ),
    );

    await exports.downloadTo(_id, file, userId: 'user-1');

    expect(await file.readAsBytes(), [80, 75, 3, 4]);
    expect(sent.single.method, 'POST');
    expect(sent.single.url.path, '/v1/me/export/$_id/download');
  });
}
