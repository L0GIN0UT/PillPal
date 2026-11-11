import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Id of the export the fake server makes.
const String fakeExportId = '00000000-0000-4000-8000-0000000000e1';

/// The bytes of the fake archive (the start of a zip).
const List<int> fakeArchiveBytes = [80, 75, 3, 4, 1, 2, 3, 4];

/// The export endpoints of the API behind a `MockClient` handler
/// (`/v1/me/export*`, ADR 0016 §8) for the tests of the export screen. The
/// consent and feature endpoints answer what the tests set; everything else
/// is 404, and a refresh is refused (the session is gone for good).
class FakeExportServer {
  /// The password the step-up accepts.
  String password = 'correct-pass';

  /// Status of the export: `queued`, `running`, `ready`, `downloaded`,
  /// `failed` or `expired`.
  String status = 'queued';

  /// `ExportOut.error_code` of a failed export.
  String? errorCode;

  /// The number of status checks after which a queued export is ready.
  int readyAfterPolls = 1;

  /// `POST /v1/me/export` answers 200 (a replay) instead of 202.
  bool requestIsReplay = false;

  /// `POST /v1/me/export` answers this (status, code) instead.
  (int, String)? requestFailure;

  /// `Retry-After` (seconds) sent with [requestFailure].
  int? retryAfterSeconds;

  /// The status check answers this (status, code) while set.
  (int, String)? statusFailure;

  /// What the download does; null serves the archive and claims it.
  Future<http.Response> Function()? onDownload;

  /// A download that is claimed (the status becomes `downloaded`) and then
  /// breaks: the transfer fails after the commit.
  bool breakAfterClaim = false;

  /// A download that breaks before the claim (the export stays `ready`).
  bool breakBeforeClaim = false;

  /// While set, the download waits for it (a transfer in flight).
  Completer<void>? holdDownload;

  /// Every request, in order.
  final List<http.Request> requests = [];

  int _polls = 0;

  /// The requests as `METHOD path`.
  List<String> get calls => [
        for (final request in requests) '${request.method} ${request.url.path}',
      ];

  /// How many requests went to [path] (exact).
  int count(String path) =>
      requests.where((request) => request.url.path == path).length;

  /// Status checks made.
  int get statusChecks => count('/v1/me/export/$fakeExportId');

  /// Downloads attempted.
  int get downloads => count('/v1/me/export/$fakeExportId/download');

  /// `ExportOut` as the server shows it now.
  Map<String, Object?> exportJson() => {
        'id': fakeExportId,
        'status': status,
        'requested_at': '2026-11-11T08:00:00Z',
        if (status == 'ready') ...{
          'ready_at': '2026-11-11T08:01:00Z',
          'expires_at': '2026-11-12T08:01:00Z',
          'size_bytes': fakeArchiveBytes.length,
        },
        if (errorCode != null) 'error_code': errorCode,
      };

  /// The `MockClient` handler.
  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (path == '/v1/auth/refresh') {
      return _error(401, 'token_reused');
    }
    if (path == '/v1/me/export') {
      return _request(request);
    }
    if (path == '/v1/me/export/$fakeExportId') {
      return _status();
    }
    if (path == '/v1/me/export/$fakeExportId/download') {
      return _download();
    }
    return _error(404, 'not_found');
  }

  http.Response _request(http.Request request) {
    final failure = requestFailure;
    if (failure != null) {
      return _error(failure.$1, failure.$2, retryAfter: retryAfterSeconds);
    }
    final body = jsonDecode(request.body) as Map<String, Object?>;
    if (body['password'] != password) {
      return _error(401, 'invalid_password');
    }
    return _json(requestIsReplay ? 200 : 202, exportJson());
  }

  http.Response _status() {
    final failure = statusFailure;
    if (failure != null) {
      return _error(failure.$1, failure.$2);
    }
    _polls++;
    if (status == 'queued' && _polls >= readyAfterPolls) {
      status = 'ready';
    }
    return _json(200, exportJson());
  }

  Future<http.Response> _download() async {
    await holdDownload?.future;
    final custom = onDownload;
    if (custom != null) {
      return custom();
    }
    if (breakBeforeClaim) {
      throw http.ClientException('connection lost');
    }
    if (status == 'downloaded' || status == 'expired') {
      return _error(410, 'export_gone');
    }
    if (status != 'ready') {
      return _error(409, 'export_not_ready');
    }
    status = 'downloaded';
    if (breakAfterClaim) {
      throw http.ClientException('connection lost');
    }
    return http.Response.bytes(
      fakeArchiveBytes,
      200,
      headers: {'content-type': 'application/zip'},
    );
  }

  http.Response _json(int status, Map<String, Object?> body) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );

  http.Response _error(int status, String code, {int? retryAfter}) =>
      http.Response(
        jsonEncode({
          'error': {'code': code, 'message': 'synthetic'},
        }),
        status,
        headers: {
          'content-type': 'application/json',
          if (retryAfter != null) 'retry-after': '$retryAfter',
        },
      );
}
