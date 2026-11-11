import 'dart:io';

import '../config.dart';
import 'api_client.dart';
import 'api_exception.dart';
import 'export_dto.dart';
import 'json.dart';

/// `/v1/me/export*` (ADR 0016 §8). The server flag
/// `FEATURE_DATA_EXPORT` answers 403 `feature_disabled` when it is off.
///
/// Every call carries the account id, so [ApiClient] refuses it
/// (`account_changed`) when the stored session belongs to another account.
class ExportApi {
  /// Creates the API over [_client].
  ExportApi(this._client);

  final ApiClient _client;

  /// `POST /v1/me/export`: asks for an export after the step-up with
  /// [password]. 202 for a new one, 200 for a replay by the same session:
  /// both are the export to follow. A wrong password is 401
  /// `invalid_password`, a request within the cooldown is 429
  /// `export_rate_limited`.
  Future<DataExport> request(String password, {required String userId}) async {
    final json = await _client.post(
      '/v1/me/export',
      body: ExportBodies.request(password),
      forUser: userId,
    );
    return DataExport.fromJson(_require(json));
  }

  /// `GET /v1/me/export/{id}`.
  Future<DataExport> status(String id, {required String userId}) async {
    final json = await _client.get(_path(id), forUser: userId);
    return DataExport.fromJson(_require(json));
  }

  /// `POST /v1/me/export/{id}/download`: streams the zip into [file]. The
  /// server hands the archive out once and the claim commits before the
  /// bytes are sent, so this is a single attempt; see [ApiClient.downloadTo].
  Future<void> downloadTo(String id, File file, {required String userId}) =>
      _client.downloadTo(
        '${_path(id)}/download',
        file,
        forUser: userId,
        maxBytes: ExportPolicy.maxArchiveBytes,
      );

  String _path(String id) => '/v1/me/export/$id';

  JsonMap _require(JsonMap? json) {
    if (json == null) {
      throw const ApiException(ApiException.invalidResponse, 200);
    }
    return json;
  }
}
