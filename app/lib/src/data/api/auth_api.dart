import '../auth/token_store.dart';
import 'api_client.dart';
import 'auth_dto.dart';

/// Account flows exactly as `backend/app/api/auth.py` implements them.
///
/// Registration answers 202 and mails a code; [verifyEmail] with that code is
/// the first sign-in. [login] fails with 403 `email_not_verified` for an
/// unconfirmed address (after a correct password). Token refresh happens
/// inside [ApiClient].
class AuthApi {
  /// Creates the auth API.
  AuthApi(this._client, this._tokens);

  final ApiClient _client;
  final TokenStore _tokens;

  /// `POST /v1/auth/register`; always 202 (also for a known address).
  Future<void> register(RegisterRequest request) async {
    await _client.post(
      '/v1/auth/register',
      body: request.toJson(),
      authenticated: false,
    );
  }

  /// `POST /v1/auth/verify-email/resend`; always 202.
  Future<void> resendVerification(String email) async {
    await _client.post(
      '/v1/auth/verify-email/resend',
      body: AuthBodies.resendVerification(email),
      authenticated: false,
    );
  }

  /// `POST /v1/auth/verify-email`: confirms the address and signs in.
  Future<void> verifyEmail({required String email, required String code}) async {
    final json = await _client.post(
      '/v1/auth/verify-email',
      body: AuthBodies.verifyEmail(email, code),
      authenticated: false,
    );
    await _client.saveTokens(json);
  }

  /// `POST /v1/auth/login`.
  Future<void> login({required String email, required String password}) async {
    final json = await _client.post(
      '/v1/auth/login',
      body: AuthBodies.login(email, password),
      authenticated: false,
    );
    await _client.saveTokens(json);
  }

  /// `POST /v1/auth/logout`, then forgets the tokens even if the call fails.
  Future<void> logout() async {
    final tokens = await _tokens.read();
    if (tokens == null) {
      return;
    }
    try {
      await _client.post(
        '/v1/auth/logout',
        body: AuthBodies.refresh(tokens.refreshToken),
        authenticated: false,
      );
    } finally {
      await _tokens.clear();
    }
  }

  /// Whether tokens are stored (the session may still turn out revoked).
  Future<bool> isSignedIn() async => await _tokens.read() != null;

  /// `GET /v1/me`.
  Future<UserInfo> me() async {
    final json = await _client.get('/v1/me');
    if (json == null) {
      throw const FormatException('Empty /v1/me response');
    }
    return UserInfo.fromJson(json);
  }
}
