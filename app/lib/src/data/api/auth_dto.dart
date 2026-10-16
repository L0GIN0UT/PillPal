import 'json.dart';

/// Access + refresh token pair (`TokenPair`).
class TokenPair {
  /// Creates a token pair.
  const TokenPair({
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
  });

  /// Parses a `TokenPair` response received at [receivedAt].
  factory TokenPair.fromJson(JsonMap json, DateTime receivedAt) {
    final reader = JsonReader(json, readKeys);
    return TokenPair(
      accessToken: reader.string('access_token'),
      refreshToken: reader.string('refresh_token'),
      accessExpiresAt: receivedAt.toUtc().add(
            Duration(seconds: reader.integer('expires_in')),
          ),
    );
  }

  /// Keys read from `TokenPair`.
  static const Set<String> readKeys = {
    'access_token',
    'refresh_token',
    'expires_in',
  };

  /// Short-lived bearer token (JWT).
  final String accessToken;

  /// Opaque single-use refresh token (rotated on every refresh).
  final String refreshToken;

  /// When [accessToken] expires (client clock).
  final DateTime accessExpiresAt;
}

/// `RegisterRequest` body.
class RegisterRequest {
  /// Creates a registration request.
  const RegisterRequest({
    required this.email,
    required this.password,
    required this.region,
    required this.locale,
    required this.timezone,
    this.displayName,
  });

  /// Sign-in e-mail.
  final String email;

  /// Password, 8..128 characters.
  final String password;

  /// Must equal the server's region (else 409 `wrong_region`).
  final String region;

  /// `ru` or `en`.
  final String locale;

  /// IANA zone of the device, used for the `self` profile.
  final String timezone;

  /// Optional name for the `self` profile.
  final String? displayName;

  /// Wire form.
  JsonMap toJson() => {
        'email': email,
        'password': password,
        'region': region,
        'locale': locale,
        'timezone': timezone,
        if (displayName != null) 'display_name': displayName,
      };
}

/// Wire bodies of the remaining auth requests.
abstract final class AuthBodies {
  /// `LoginRequest`.
  static JsonMap login(String email, String password) =>
      {'email': email, 'password': password};

  /// `VerifyEmailRequest`.
  static JsonMap verifyEmail(String email, String code) =>
      {'email': email, 'code': code};

  /// `ResendVerificationRequest`.
  static JsonMap resendVerification(String email) => {'email': email};

  /// `RefreshRequest` (also the body of logout).
  static JsonMap refresh(String refreshToken) =>
      {'refresh_token': refreshToken};
}

/// The signed-in account (`UserOut`).
class UserInfo {
  /// Creates account info.
  const UserInfo({
    required this.id,
    required this.email,
    required this.emailVerified,
    required this.region,
    required this.locale,
  });

  /// Parses `UserOut`.
  factory UserInfo.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return UserInfo(
      id: reader.string('id'),
      email: reader.string('email'),
      emailVerified: reader.boolean('email_verified'),
      region: reader.string('region'),
      locale: reader.string('locale'),
    );
  }

  /// Keys read from `UserOut`.
  static const Set<String> readKeys = {
    'id',
    'email',
    'email_verified',
    'region',
    'locale',
  };

  /// User id.
  final String id;

  /// Lowercased e-mail.
  final String email;

  /// Whether the address is confirmed.
  final bool emailVerified;

  /// Data region of the account.
  final String region;

  /// `ru` or `en`.
  final String locale;
}
