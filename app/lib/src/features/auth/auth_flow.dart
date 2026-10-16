import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/auth_dto.dart';
import '../../data/providers.dart';
import '../common/local_time.dart';
import 'auth_session.dart';

/// Client-side validation limits mirrored from `RegisterRequest`.
abstract final class AuthLimits {
  /// Minimum password length.
  static const int passwordMin = 8;

  /// Maximum password length.
  static const int passwordMax = 128;

  /// Digits in an e-mail verification code.
  static const int codeLength = 6;
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

  /// Anything unexpected.
  static const String generic = 'generic';
}

final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// State of the onboarding screens.
@immutable
class AuthFlowState {
  /// Creates a state.
  const AuthFlowState({
    this.region,
    this.email,
    this.busy = false,
    this.errorCode,
  });

  /// Confirmed data region (null until confirmed).
  final DataRegion? region;

  /// Address awaiting its verification code.
  final String? email;

  /// A request is in flight.
  final bool busy;

  /// Error of the last action (server or [AuthClientErrors] code).
  final String? errorCode;

  /// Copy with [busy] and [errorCode] replaced (error cleared if omitted).
  AuthFlowState copyWith({
    DataRegion? region,
    String? email,
    bool? busy,
    String? errorCode,
  }) {
    return AuthFlowState(
      region: region ?? this.region,
      email: email ?? this.email,
      busy: busy ?? this.busy,
      errorCode: errorCode,
    );
  }
}

/// What a login attempt led to.
enum LoginOutcome {
  /// Signed in.
  signedIn,

  /// The address is not verified yet: a new code was sent.
  needsVerification,

  /// Failed; see [AuthFlowState.errorCode].
  failed,
}

/// Onboarding actions: region, register, verify, login.
final authFlowProvider = NotifierProvider<AuthFlowController, AuthFlowState>(
  AuthFlowController.new,
);

/// Drives the onboarding screens; widgets only render [AuthFlowState].
class AuthFlowController extends Notifier<AuthFlowState> {
  @override
  AuthFlowState build() => const AuthFlowState();

  /// Confirms the data region.
  void confirmRegion(DataRegion region) {
    state = state.copyWith(region: region);
  }

  /// Clears a shown error (e.g. when the user edits a field).
  void clearError() {
    if (state.errorCode != null) {
      state = state.copyWith();
    }
  }

  /// Whether a session exists: the onboarding actions then refuse to run, so
  /// no second account can sign in over it (the router also keeps signed-in
  /// users away from these screens).
  bool get _sessionActive => ref.read(authSessionProvider).valueOrNull ?? false;

  /// Registers; true when a code was sent to [email].
  Future<bool> register({
    required String email,
    required String password,
    required String locale,
  }) async {
    if (_sessionActive) {
      return false;
    }
    final normalized = email.trim().toLowerCase();
    final invalid = validateEmail(normalized) ?? validatePassword(password);
    if (invalid != null) {
      state = state.copyWith(errorCode: invalid);
      return false;
    }
    final region = state.region ?? DataRegion.ru;
    return _run(() async {
      await ref.read(authApiProvider).register(
            RegisterRequest(
              email: normalized,
              password: password,
              region: region.wire,
              locale: locale == 'ru' ? 'ru' : 'en',
              timezone: ref.read(deviceTimeZoneProvider),
            ),
          );
      state = state.copyWith(email: normalized);
    });
  }

  /// Confirms the address with [code]; true when signed in.
  Future<bool> verify(String code) async {
    final email = state.email;
    final digits = code.trim();
    if (email == null || _sessionActive) {
      state = state.copyWith(errorCode: AuthClientErrors.generic);
      return false;
    }
    if (!RegExp('^[0-9]{${AuthLimits.codeLength}}\$').hasMatch(digits)) {
      state = state.copyWith(errorCode: AuthClientErrors.invalidCode);
      return false;
    }
    return _run(() async {
      await ref.read(authApiProvider).verifyEmail(email: email, code: digits);
      _signedIn();
    });
  }

  /// Sends a new verification code.
  Future<bool> resendCode() async {
    final email = state.email;
    if (email == null) {
      return false;
    }
    return _run(
      () => ref.read(authApiProvider).resendVerification(email),
    );
  }

  /// Signs in with e-mail and password.
  Future<LoginOutcome> login({
    required String email,
    required String password,
  }) async {
    if (_sessionActive) {
      return LoginOutcome.failed;
    }
    final normalized = email.trim().toLowerCase();
    final invalid = validateEmail(normalized);
    if (invalid != null || password.isEmpty) {
      state = state.copyWith(
        errorCode: invalid ?? AuthClientErrors.passwordTooShort,
      );
      return LoginOutcome.failed;
    }
    state = state.copyWith(busy: true);
    try {
      await ref.read(authApiProvider).login(
            email: normalized,
            password: password,
          );
      state = state.copyWith(busy: false);
      _signedIn();
      return LoginOutcome.signedIn;
    } on ApiException catch (error) {
      if (error.code == 'email_not_verified') {
        state = state.copyWith(busy: false, email: normalized);
        await resendCode();
        return LoginOutcome.needsVerification;
      }
      state = state.copyWith(busy: false, errorCode: error.code);
      return LoginOutcome.failed;
    }
  }

  void _signedIn() {
    ref.read(authSessionProvider.notifier).markSignedIn();
    // The self profile and existing data arrive with the first pull.
    requestSyncFrom(ref);
  }

  Future<bool> _run(Future<void> Function() action) async {
    state = state.copyWith(busy: true);
    try {
      await action();
      state = state.copyWith(busy: false);
      return true;
    } on ApiException catch (error) {
      state = state.copyWith(busy: false, errorCode: error.code);
      return false;
    } on FormatException {
      state = state.copyWith(
        busy: false,
        errorCode: ApiException.invalidResponse,
      );
      return false;
    }
  }
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
