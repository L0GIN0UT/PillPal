import '../data/api/api_client.dart';
import 'push_provider_client.dart';

/// Registering and removing this installation's push token.
abstract interface class PushTokenGateway {
  /// Registers or replaces this device's token. [forUser] binds the request
  /// to the account the registration is for.
  Future<void> register({
    required PushProviderKind provider,
    required PushRegistration registration,
    String? forUser,
  });

  /// Removes this device's token (idempotent).
  Future<void> unregister({String? forUser});
}

/// The push token endpoints of `backend/app/api/push.py` (ADR 0008 §1): one
/// token per installation, identified by `X-Device-ID`. The token is
/// write-only on the server and never appears in a log or an error.
class PushApi implements PushTokenGateway {
  /// Creates the API over [_client].
  PushApi(this._client);

  final ApiClient _client;

  /// `PUT /v1/push-tokens/current`.
  @override
  Future<void> register({
    required PushProviderKind provider,
    required PushRegistration registration,
    String? forUser,
  }) async {
    await _client.put(
      '/v1/push-tokens/current',
      body: {
        'provider': provider.wire,
        'token': registration.token,
        if (registration.apnsEnvironment != null)
          'apns_environment': registration.apnsEnvironment,
      },
      forUser: forUser,
    );
  }

  /// `DELETE /v1/push-tokens/current` (204 without a token as well).
  @override
  Future<void> unregister({String? forUser}) async {
    await _client.delete('/v1/push-tokens/current', forUser: forUser);
  }
}
