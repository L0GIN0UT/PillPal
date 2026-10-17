import 'api_client.dart';
import 'api_exception.dart';
import 'json.dart';
import 'relatives_dto.dart';

/// The relatives endpoints of `backend/app/api/relatives.py` and the
/// account deletion of `backend/app/api/auth.py`.
///
/// Relatives never reach another profile's data over REST (ADR 0005): this
/// API is about links, invites and the account itself.
class RelativesApi {
  /// Creates the API over [_client].
  RelativesApi(this._client);

  final ApiClient _client;

  /// `POST /v1/profiles/{id}/invites`. The id is the client's UUID, so a
  /// lost response can be retried: the replay answers 409 `already_exists`.
  Future<InviteCreated> createInvite({
    required String profileId,
    required String inviteId,
    required String role,
    required int disclosureVersion,
  }) async {
    final json = await _client.post(
      '/v1/profiles/$profileId/invites',
      body: RelativesBodies.createInvite(
        id: inviteId,
        role: role,
        disclosureVersion: disclosureVersion,
      ),
    );
    return InviteCreated.fromJson(_require(json));
  }

  /// `GET /v1/profiles/{id}/invites`: open invites, without tokens.
  Future<List<InviteSummary>> listInvites(String profileId) async {
    final json = await _client.get('/v1/profiles/$profileId/invites');
    final reader = JsonReader(_require(json), const {'items'});
    return [
      for (final item in reader.list('items'))
        InviteSummary.fromJson(asJsonMap(item, 'invite')),
    ];
  }

  /// `DELETE /v1/profiles/{id}/invites/{invite_id}`: revokes (idempotent).
  Future<void> revokeInvite(String profileId, String inviteId) async {
    await _client.delete('/v1/profiles/$profileId/invites/$inviteId');
  }

  /// `POST /v1/invites/preview`. The token travels in the body only.
  Future<InvitePreview> previewInvite(String token) async {
    final json = await _client.post(
      '/v1/invites/preview',
      body: RelativesBodies.token(token),
    );
    return InvitePreview.fromJson(_require(json));
  }

  /// `POST /v1/invites/accept`: the explicit confirmation of the invitee.
  Future<IncomingGrant> acceptInvite(String token) async {
    final json = await _client.post(
      '/v1/invites/accept',
      body: RelativesBodies.token(token),
    );
    return IncomingGrant.fromJson(_require(json));
  }

  /// `GET /v1/grants`. With [forUser] the request fails unless the stored
  /// session is that account's (the answer is written to its local data).
  Future<GrantList> listGrants({String? forUser}) async {
    final json = await _client.get('/v1/grants', forUser: forUser);
    return GrantList.fromJson(_require(json));
  }

  /// `PATCH /v1/grants/{id}` changing the role (`viewer` or `editor`).
  Future<void> changeRole({
    required String grantId,
    required String role,
    required int disclosureVersion,
  }) async {
    await _client.patch(
      '/v1/grants/$grantId',
      body: RelativesBodies.changeRole(role, disclosureVersion),
    );
  }

  /// `PATCH /v1/grants/{id}` changing the grantee's alert choice.
  Future<void> setNotifyMissed(
    String grantId, {
    required bool enabled,
  }) async {
    await _client.patch(
      '/v1/grants/$grantId',
      body: RelativesBodies.notifyMissed(enabled: enabled),
    );
  }

  /// `DELETE /v1/grants/{id}`: the owner revokes, the grantee leaves.
  Future<void> deleteGrant(String grantId) async {
    await _client.delete('/v1/grants/$grantId');
  }

  /// `DELETE /v1/profiles/{id}`: purges an archive after `owner_erased`
  /// (an owner of a live managed profile deletes it through sync).
  Future<void> purgeProfile(String profileId) async {
    await _client.delete('/v1/profiles/$profileId');
  }

  /// `GET /v1/me/features`.
  Future<AccountFeatures> features() async {
    final json = await _client.get('/v1/me/features');
    return AccountFeatures.fromJson(_require(json));
  }

  /// `DELETE /v1/me`: starts the deletion grace period (204). A wrong
  /// password is `401 invalid_password`.
  Future<void> deleteAccount(String password) async {
    await _client.delete(
      '/v1/me',
      body: RelativesBodies.deleteAccount(password),
    );
  }

  JsonMap _require(JsonMap? json) {
    if (json == null) {
      throw const ApiException(ApiException.invalidResponse, 200);
    }
    return json;
  }
}
