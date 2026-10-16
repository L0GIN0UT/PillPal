import 'dart:convert';

/// The account an access token belongs to (JWT claims `sub` and `region`).
///
/// Read without verifying the signature: the client only uses it to bind
/// local data to an account; the server verifies every token.
class AccessClaims {
  /// Creates claims.
  const AccessClaims({required this.userId, required this.region});

  /// Parses the payload of a JWT, or returns null if it is not one.
  static AccessClaims? fromToken(String token) {
    final parts = token.split('.');
    if (parts.length != 3) {
      return null;
    }
    try {
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final Object? json = jsonDecode(payload);
      if (json is! Map<String, Object?>) {
        return null;
      }
      final userId = json['sub'];
      final region = json['region'];
      if (userId is! String || region is! String) {
        return null;
      }
      return AccessClaims(userId: userId, region: region);
    } on FormatException {
      return null;
    }
  }

  /// User id.
  final String userId;

  /// Data region of the account.
  final String region;

  @override
  bool operator ==(Object other) =>
      other is AccessClaims && other.userId == userId && other.region == region;

  @override
  int get hashCode => Object.hash(userId, region);
}

/// Told when the session changes, so local data stays bound to one account.
abstract interface class SessionListener {
  /// A session for [claims] is about to be stored.
  Future<void> signingIn(AccessClaims claims);

  /// The session ended (logout or a rejected refresh token).
  Future<void> signedOut();
}
