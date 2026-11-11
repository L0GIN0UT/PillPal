import 'api_client.dart';
import 'api_exception.dart';
import 'consents_dto.dart';
import 'json.dart';

/// `GET` and `POST /v1/me/consents` (ADR 0016 §2). The server refuses nothing
/// for a missing consent; the app itself pauses the medical sync (`MedicalSyncGate`).
///
/// Every call carries the account id, so [ApiClient] refuses it
/// (`account_changed`) when the stored session belongs to another account.
class ConsentsApi {
  /// Creates the API over [_client].
  ConsentsApi(this._client);

  final ApiClient _client;

  /// What the server holds for [userId]: the versions to show, the records and
  /// the kinds still missing.
  Future<ConsentsState> get({required String userId}) async {
    final json = await _client.get('/v1/me/consents', forUser: userId);
    return ConsentsState.fromJson(_require(json));
  }

  /// Records the acceptance of [grant] (source `in_app`). 201 for a new
  /// record, 200 when the same version is already active: both are success.
  /// A version the server no longer accepts is 422
  /// `unsupported_consent_version`.
  Future<ConsentRecord> accept(
    ConsentGrant grant, {
    required String userId,
  }) async {
    final json = await _client.post(
      '/v1/me/consents',
      body: grant.toJson(),
      forUser: userId,
    );
    return ConsentRecord.fromJson(_require(json));
  }

  /// `POST /v1/me/consents/withdraw`: withdraws [kind]. Only the catalog
  /// contribution can be withdrawn this way (the server resets the account's
  /// links to the catalog); the other kinds are withdrawn by deleting the
  /// account and answer 409 `withdraw_via_account_deletion`. Returns how many
  /// links were reset (a replay: 0).
  Future<int> withdraw(ConsentKind kind, {required String userId}) async {
    final json = await _client.post(
      '/v1/me/consents/withdraw',
      body: ConsentBodies.withdraw(kind),
      forUser: userId,
    );
    return JsonReader(
      _require(json),
      ConsentBodies.withdrawReadKeys,
    ).integer('reset_links');
  }

  JsonMap _require(JsonMap? json) {
    if (json == null) {
      throw const ApiException(ApiException.invalidResponse, 200);
    }
    return json;
  }
}
