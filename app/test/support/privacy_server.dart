import 'dart:convert';

import 'package:http/http.dart' as http;

import 'consent_server.dart';
import 'export_server.dart';

/// The endpoints behind «Приватность и данные» and the export: consents (with
/// the withdrawal of the catalog contribution), features, the account and the
/// export, for the widget tests of both screens.
class FakePrivacyServer {
  /// The consents; its records are what the screen lists.
  final FakeConsentServer consents = FakeConsentServer();

  /// The export endpoints.
  final FakeExportServer exports = FakeExportServer();

  /// `FeaturesOut.data_export_enabled`.
  bool exportEnabled = true;

  /// `UserOut.has_password`.
  bool hasPassword = true;

  /// Links a withdrawal of the contribution resets.
  int linksReset = 2;

  /// `POST /v1/me/consents/withdraw` answers this (status, code) instead.
  (int, String)? withdrawFailure;

  /// Kinds withdrawn, in order.
  final List<String> withdrawn = [];

  /// Every request, in order.
  final List<http.Request> requests = [];

  /// The requests as `METHOD path`.
  List<String> get calls => [
        for (final request in requests) '${request.method} ${request.url.path}',
      ];

  /// The `MockClient` handler.
  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (path.startsWith('/v1/me/export')) {
      return exports.handle(request);
    }
    switch (path) {
      case '/v1/me/consents/withdraw':
        return _withdraw(request);
      case '/v1/me/features':
        return _json(200, {
          'soft_limits_enabled': false,
          'relatives_limit': null,
          'pdf_reports_limit': null,
          'account_deletion_grace_days': 30,
          'managed_archive_retention_days': 90,
          'catalog_contributions_enabled': true,
          'data_export_enabled': exportEnabled,
          'consent_required_kinds': <String>[],
        });
      case '/v1/me':
        return _json(200, {
          'id': 'user-1',
          'email': 'user@example.test',
          'email_verified': true,
          'has_password': hasPassword,
          'region': 'ru',
          'locale': 'en',
          'created_at': '2026-10-16T08:00:00Z',
        });
    }
    return consents.handle(request);
  }

  http.Response _withdraw(http.Request request) {
    final failure = withdrawFailure;
    if (failure != null) {
      return _json(failure.$1, {
        'error': {'code': failure.$2, 'message': 'synthetic'},
      });
    }
    final kind =
        (jsonDecode(request.body) as Map<String, Object?>)['kind']! as String;
    withdrawn.add(kind);
    // A withdrawn record stays in the list as history.
    consents.records = [
      for (final record in consents.records)
        if (record['kind'] == kind)
          consentRecord(kind, withdrawn: true)
        else
          record,
    ];
    return _json(200, {'reset_links': linksReset});
  }

  http.Response _json(int status, Map<String, Object?> body) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );
}
