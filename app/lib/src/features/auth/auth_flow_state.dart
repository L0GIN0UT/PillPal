import 'package:flutter/foundation.dart';

import '../../data/api/relatives_dto.dart';

/// Client-side validation limits mirrored from `RegisterRequest`.
abstract final class AuthLimits {
  /// Minimum password length.
  static const int passwordMin = 8;

  /// Maximum password length.
  static const int passwordMax = 128;

  /// Digits in an e-mail verification code.
  static const int codeLength = 6;

  /// How long a mailed code is valid (the server's `email_code_ttl_seconds`).
  static const int codeTtlMinutes = 15;

  /// Failed confirmations of a password change after which «Forgot
  /// password?» is offered: another session may be blocking the change.
  static const int changeFailuresBeforeForgot = 2;

  /// Minimum time between two requests of a mailed code from one screen.
  static const Duration resendCooldown = Duration(seconds: 30);
}

/// Steps of the registration for the «Step N of M» indicator (docs/design/b2
/// README, redesign plan Q7): credentials, then the mailed code. The consent
/// step (A1) will raise `total` to 3.
///
/// The numbers come from the order of the values, so A1 adds the consent step
/// in one place and every indicator follows («Step N of 2» until then).
enum RegistrationStep {
  /// E-mail and password.
  credentials,

  /// The mailed code.
  code;

  /// 1-based number shown to the user.
  int get number => index + 1;

  /// Steps in all.
  static int get total => values.length;
}

/// Error codes produced on the client before any request.
abstract final class AuthClientErrors {
  /// The e-mail address is malformed.
  static const String invalidEmail = 'invalid_email';

  /// The password is shorter than [AuthLimits.passwordMin].
  static const String passwordTooShort = 'password_too_short';

  /// The password is longer than [AuthLimits.passwordMax].
  static const String passwordTooLong = 'password_too_long';

  /// The code is not [AuthLimits.codeLength] digits.
  static const String invalidCode = 'invalid_code_format';

  /// The session ended while the request was running.
  static const String sessionEnded = 'session_ended';

  /// Anything unexpected.
  static const String generic = 'generic';
}

final RegExp _codePattern = RegExp('^[0-9]{${AuthLimits.codeLength}}\$');
final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// State of the onboarding screens.
@immutable
class AuthFlowState {
  /// Creates a state.
  const AuthFlowState({
    this.email,
    this.restore,
    this.busy = false,
    this.errorCode,
  });

  /// Address awaiting its verification code.
  final String? email;

  /// An account in its deletion grace period waiting for its restore code
  /// (ADR 0010 §2). The ticket lives in memory only.
  final PendingDeletion? restore;

  /// A request is in flight.
  final bool busy;

  /// Error of the last action (server or [AuthClientErrors] code).
  final String? errorCode;

  /// Copy with [busy] and [errorCode] replaced (error cleared if omitted).
  AuthFlowState copyWith({
    String? email,
    PendingDeletion? restore,
    bool? busy,
    String? errorCode,
  }) {
    return AuthFlowState(
      email: email ?? this.email,
      restore: restore ?? this.restore,
      busy: busy ?? this.busy,
      errorCode: errorCode,
    );
  }
}

/// Result of [AuthFlowController.resetPassword].
typedef PasswordResetResult = ({bool changed, LoginOutcome login});

/// What a login attempt led to.
enum LoginOutcome {
  /// Signed in.
  signedIn,

  /// The address is not verified yet: a new code was sent.
  needsVerification,

  /// The account is being deleted and can still be restored: the restore
  /// screen asks for the code that was mailed.
  needsRestore,

  /// Failed; see [AuthFlowState.errorCode].
  failed,
}

/// [AuthClientErrors.invalidEmail] for a malformed address, else null.
String? validateEmail(String email) =>
    _emailPattern.hasMatch(email) ? null : AuthClientErrors.invalidEmail;

/// A password length error code, else null.
String? validatePassword(String password) {
  if (password.length < AuthLimits.passwordMin) {
    return AuthClientErrors.passwordTooShort;
  }
  if (password.length > AuthLimits.passwordMax) {
    return AuthClientErrors.passwordTooLong;
  }
  return null;
}

/// Whether [code] (already trimmed) is a well-formed one-time code.
bool isWellFormedCode(String code) => _codePattern.hasMatch(code);

/// What the sign-in route is opened with after a password reset whose
/// automatic sign-in failed: the address is prefilled and a notice says the
/// password was changed. The new password is never carried along.
@immutable
class LoginRouteArgs {
  /// Creates the arguments.
  const LoginRouteArgs({this.email, this.passwordChanged = false});

  /// Address to prefill.
  final String? email;

  /// The password was just replaced; sign in with the new one.
  final bool passwordChanged;
}
