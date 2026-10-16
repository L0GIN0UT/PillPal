import 'dart:convert';

import 'package:flutter/services.dart';
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

/// Answers true exactly once per installation (backed by the local database,
/// which is excluded from backups).
typedef FreshInstallCheck = Future<bool> Function();

/// [TokenStore] in the platform keystore (Keychain / Android Keystore).
///
/// The pair is one JSON value under one key, so it is replaced atomically.
/// The iOS Keychain survives uninstalling the app, so on the first read of a
/// new installation everything this app stored there is deleted. Unreadable
/// entries (e.g. after a backup restore to another device) read as signed out.
class SecureTokenStore implements TokenStore {
  /// Creates a store backed by [storage].
  SecureTokenStore({
    required FreshInstallCheck isFreshInstall,
    FlutterSecureStorage? storage,
  })  : _isFreshInstall = isFreshInstall,
        _storage = storage ?? const FlutterSecureStorage(aOptions: android, iOptions: ios);

  /// Keystore-backed, reset (instead of crashing) when keys were lost.
  static const AndroidOptions android = AndroidOptions(
    encryptedSharedPreferences: true,
    resetOnError: true,
  );

  /// Only on this device, readable after the first unlock (background sync).
  static const IOSOptions ios = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );

  static const String _key = 'pillpal.session';

  final FreshInstallCheck _isFreshInstall;
  final FlutterSecureStorage _storage;
  Future<void>? _ready;

  Future<void> _prepare() => _ready ??= _resetIfFreshInstall();

  Future<void> _resetIfFreshInstall() async {
    if (await _isFreshInstall()) {
      try {
        await _storage.deleteAll();
      } on PlatformException {
        // Nothing readable is left either way.
      }
    }
  }

  @override
  Future<TokenPair?> read() async {
    await _prepare();
    final String? raw;
    try {
      raw = await _storage.read(key: _key);
    } on PlatformException {
      return null;
    }
    return raw == null ? null : decode(raw);
  }

  @override
  Future<void> write(TokenPair tokens) async {
    await _prepare();
    await _storage.write(key: _key, value: encode(tokens));
  }

  @override
  Future<void> clear() async {
    await _prepare();
    try {
      await _storage.delete(key: _key);
    } on PlatformException {
      // Already unreadable.
    }
  }

  /// The stored form of [tokens].
  static String encode(TokenPair tokens) => jsonEncode({
        'access_token': tokens.accessToken,
        'refresh_token': tokens.refreshToken,
        'access_expires_at': tokens.accessExpiresAt.toUtc().toIso8601String(),
      });

  /// Parses [encode]'s output; null if it is damaged.
  static TokenPair? decode(String raw) {
    try {
      final Object? json = jsonDecode(raw);
      if (json is! Map<String, Object?>) {
        return null;
      }
      final access = json['access_token'];
      final refresh = json['refresh_token'];
      final expires = json['access_expires_at'];
      if (access is! String || refresh is! String || expires is! String) {
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
    } on FormatException {
      return null;
    }
  }
}
