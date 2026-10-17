import '../auth/token_store.dart';
import 'api_client.dart';
import 'api_exception.dart';
import 'auth_dto.dart';

/// Pushes pending local changes before a sign-out (best effort).
typedef OutboxFlush = Future<void> Function();

/// Account flows exactly as `backend/app/api/auth.py` implements them.
///
/// Registration answers 202 and mails a code; [verifyEmail] with that code is
/// the first sign-in. [login] fails with 403 `email_not_verified` for an
/// unconfirmed address (after a correct password). Token refresh happens
/// inside [ApiClient]. Signing in as another account, and [logout], erase
/// the local data (see `AccountBinding`).
class AuthApi {
  /// Creates the auth API; [flush] runs before [logout].
  AuthApi(
    this._client,
    this._tokens, {
    OutboxFlush? flush,
    Future<void> Function()? beforeLogout,
    this.beforeLogoutTimeout = const Duration(seconds: 5),
  })  : _flush = flush,
        _beforeLogout = beforeLogout;

  /// How long [logout] waits for the before-logout hook.
  final Duration beforeLogoutTimeout;

  /// Runs while the session still works, e.g. to delete the push token.
  final Future<void> Function()? _beforeLogout;

  final ApiClient _client;
  final TokenStore _tokens;
  final OutboxFlush? _flush;

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
  Future<void> verifyEmail(
      {required String email, required String code}) async {
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

  /// `POST /v1/auth/restore`: restores an account in its deletion grace
  /// period with the ticket of the `account_pending_deletion` login error
  /// and the code mailed with it, and signs in.
  Future<void> restore({required String ticket, required String code}) async {
    final json = await _client.post(
      '/v1/auth/restore',
      body: AuthBodies.restore(ticket, code),
      authenticated: false,
    );
    await _client.saveTokens(json);
  }

  /// Forgets the session and erases the local data of this account, without
  /// asking the server: its tokens are already revoked (account deletion).
  Future<void> forgetSession() => _client.signOutLocally();

  /// Signs out: pushes pending changes (best effort), revokes the refresh
  /// token on the server (best effort), then forgets the tokens and erases
  /// the local data of this account. Never throws for network errors.
  Future<void> logout() async {
    final tokens = await _tokens.read();
    if (tokens == null) {
      await _client.signOutLocally();
      return;
    }
    try {
      await _flush?.call();
    } on ApiException {
      // Unsynced changes are lost with the local data; sign-out goes on.
    }
    await _runBeforeLogout();
    try {
      await _client.post(
        '/v1/auth/logout',
        body: AuthBodies.refresh(tokens.refreshToken),
        authenticated: false,
      );
    } on ApiException {
      // Offline: the token expires on its own; it is gone from the device.
    } finally {
      await _client.signOutLocally();
    }
  }

  /// The hook is best effort and bounded: a provider that hangs or fails
  /// must not keep the user signed in.
  Future<void> _runBeforeLogout() async {
    try {
      await _beforeLogout?.call().timeout(beforeLogoutTimeout);
    } on Object {
      // Intentionally silent: the revoked session drops the token server-side.
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
