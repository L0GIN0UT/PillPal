import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/auth_dto.dart';

/// Persistence of the session tokens.
abstract interface class TokenStore {
  /// The stored tokens, or null when signed out.
  Future<TokenPair?> read();

  /// Replaces the stored tokens.
  Future<void> write(TokenPair tokens);

  /// Forgets the tokens (sign-out).
  Future<void> clear();
}

/// Volatile [TokenStore] for tests and previews.
class InMemoryTokenStore implements TokenStore {
  /// Creates a store, optionally signed in with [initial].
  InMemoryTokenStore([this._tokens]);

  TokenPair? _tokens;

  @override
  Future<TokenPair?> read() async => _tokens;

  @override
  Future<void> write(TokenPair tokens) async {
    _tokens = tokens;
  }

  @override
  Future<void> clear() async {
    _tokens = null;
  }
}

/// [TokenStore] in the platform keystore (Keychain / Android Keystore).
class SecureTokenStore implements TokenStore {
  /// Creates a store backed by [storage].
  SecureTokenStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const String _accessKey = 'pillpal.access_token';
  static const String _refreshKey = 'pillpal.refresh_token';
  static const String _expiresKey = 'pillpal.access_expires_at';

  final FlutterSecureStorage _storage;

  @override
  Future<TokenPair?> read() async {
    final access = await _storage.read(key: _accessKey);
    final refresh = await _storage.read(key: _refreshKey);
    final expires = await _storage.read(key: _expiresKey);
    if (access == null || refresh == null || expires == null) {
      return null;
    }
    final expiresAt = DateTime.tryParse(expires);
    if (expiresAt == null) {
      return null;
    }
    return TokenPair(
      accessToken: access,
      refreshToken: refresh,
      accessExpiresAt: expiresAt.toUtc(),
    );
  }

  @override
  Future<void> write(TokenPair tokens) async {
    await _storage.write(key: _accessKey, value: tokens.accessToken);
    await _storage.write(key: _refreshKey, value: tokens.refreshToken);
    await _storage.write(
      key: _expiresKey,
      value: tokens.accessExpiresAt.toUtc().toIso8601String(),
    );
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
    await _storage.delete(key: _expiresKey);
  }
}
