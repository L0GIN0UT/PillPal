import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/auth_dto.dart';
import '../../data/api/relatives_dto.dart';
import '../../data/providers.dart';
import '../common/local_time.dart';
import '../consent/consent_documents.dart';
import 'auth_flow_state.dart';
import 'auth_session.dart';

export 'auth_flow_state.dart';

/// Server codes that mean the consent versions of the app are not accepted.
const Set<String> _consentRefusals = {
  'unsupported_consent_version',
  'consent_required',
};

/// Onboarding actions: register, verify, login.
final authFlowProvider = NotifierProvider<AuthFlowController, AuthFlowState>(
  AuthFlowController.new,
);

/// Drives the onboarding screens; widgets only render [AuthFlowState].
class AuthFlowController extends Notifier<AuthFlowState> {
  /// The password of step 1 while the user reads the consents (step 2). Only
  /// here: never in [AuthFlowState], on disk or in a log; wiped after the
  /// registration, on a session change and when another flow starts.
  String? _heldPassword;

  /// The address of step 1. Kept apart from [AuthFlowState.email], which other
  /// flows (password reset, the code screens) read: an abandoned registration
  /// must not satisfy their guards or prefill their screens. Published to the
  /// state only when the registration succeeded.
  String? _heldEmail;

  @override
  AuthFlowState build() {
    // A new or ended session starts the onboarding afresh (no stale address
    // or error from an earlier attempt). Listened, not watched: a rebuild in
    // the middle of verify/login would invalidate this notifier's ref.
    ref.listen(
      authSessionProvider.select((session) => session.valueOrNull),
      (previous, next) {
        if (previous != next) {
          _heldPassword = null;
          _heldEmail = null;
          state = const AuthFlowState();
        }
      },
    );
    return const AuthFlowState();
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

  /// Leaves a registration that was not finished (back from the consent
  /// step): the held credentials are dropped. After a successful request
  /// nothing is held any more and the code step keeps its state.
  void abandonRegistration() {
    if (state.credentialsHeld) {
      _discardRegistration();
    }
  }

  void _discardRegistration() {
    _heldPassword = null;
    _heldEmail = null;
    state = state.copyWith(credentialsHeld: false, registering: false);
  }

  /// Step 1 of the registration: checks the credentials on the device and
  /// holds them for step 2. Nothing is sent; true when the consents can be
  /// shown.
  bool continueRegistration({required String email, required String password}) {
    if (_sessionActive) {
      return false;
    }
    final normalized = email.trim().toLowerCase();
    final invalid = validateEmail(normalized) ?? validatePassword(password);
    if (invalid != null) {
      _heldPassword = null;
      _heldEmail = null;
      state = state.copyWith(errorCode: invalid, credentialsHeld: false);
      return false;
    }
    _heldPassword = password;
    _heldEmail = normalized;
    state = state.copyWith(registering: true, credentialsHeld: true);
    return true;
  }

  /// Step 2 of the registration: registers in the region this build serves
  /// with the held credentials and the consent texts of that region; true
  /// when a code was sent.
  ///
  /// Until Phase 5 the region is fixed by the build (`PILLPAL_REGION`, TZ §1):
  /// the request goes to that region's server, so no other region can be
  /// chosen here. The device zone is sent only when the platform reported
  /// one; otherwise the server keeps its default until the profile is edited.
  /// A server that no longer knows the consent versions (422) means the app
  /// is out of date.
  Future<bool> register({required String locale}) async {
    final email = _heldEmail;
    final password = _heldPassword;
    if (_sessionActive || email == null || password == null) {
      state = state.copyWith(errorCode: AuthClientErrors.generic);
      return false;
    }
    final region = ref.read(apiConfigProvider).region;
    final sent = await _run(() async {
      final zone = await ref.read(platformTimeZoneProvider.future);
      try {
        await ref.read(authApiProvider).register(
              RegisterRequest(
                email: email,
                password: password,
                region: region,
                locale: locale == 'ru' ? 'ru' : 'en',
                timezone: zone,
                consents: ConsentDocuments.grantsFor(region),
              ),
            );
      } on ApiException catch (error) {
        if (_consentRefusals.contains(error.code)) {
          throw const ApiException(AuthClientErrors.consentOutdated, 422);
        }
        rethrow;
      }
    });
    if (sent) {
      _heldPassword = null;
      _heldEmail = null;
      state = state.copyWith(email: email, credentialsHeld: false);
    }
    return sent;
  }

  /// Confirms the address with [code]; true when signed in.
  Future<bool> verify(String code) async {
    final email = state.email;
    final digits = code.trim();
    if (email == null || _sessionActive) {
      state = state.copyWith(errorCode: AuthClientErrors.generic);
      return false;
    }
    if (!isWellFormedCode(digits)) {
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

  /// Mails a password-reset code to [email]. True when the server accepted
  /// the request: it answers the same whether or not the address has an
  /// account, so the screens never say which (no enumeration).
  Future<bool> requestPasswordReset(String email) async {
    final normalized = email.trim().toLowerCase();
    final invalid = validateEmail(normalized);
    if (_sessionActive || invalid != null) {
      state = state.copyWith(errorCode: invalid ?? AuthClientErrors.generic);
      return false;
    }
    // Another flow starts: nothing of an abandoned registration stays.
    _discardRegistration();
    return _run(() async {
      await ref.read(authApiProvider).requestPasswordReset(normalized);
      state = state.copyWith(email: normalized);
    });
  }

  /// Sets [newPassword] with the mailed [code], then signs in with it through
  /// [login], so the verification, restore and pending-deletion branches
  /// still apply. [PasswordResetResult.changed] tells whether the password
  /// was replaced (the code is spent then, whatever the sign-in did).
  Future<PasswordResetResult> resetPassword({
    required String code,
    required String newPassword,
  }) async {
    const unchanged = (changed: false, login: LoginOutcome.failed);
    final email = state.email;
    final digits = code.trim();
    final inputError = email == null || _sessionActive
        ? AuthClientErrors.generic
        : isWellFormedCode(digits)
            ? validatePassword(newPassword)
            : AuthClientErrors.invalidCode;
    if (email == null || inputError != null) {
      state = state.copyWith(errorCode: inputError);
      return unchanged;
    }
    final changed = await _run(
      () => ref.read(authApiProvider).confirmPasswordReset(
            email: email,
            code: digits,
            newPassword: newPassword,
          ),
    );
    if (!changed) {
      return unchanged;
    }
    final outcome = await login(email: email, password: newPassword);
    return (changed: true, login: outcome);
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
    // Another flow starts: nothing of an abandoned registration stays.
    _discardRegistration();
    var outcome = LoginOutcome.failed;
    final ok = await _run(() async {
      try {
        await ref.read(authApiProvider).login(
              email: normalized,
              password: password,
            );
      } on ApiException catch (error) {
        if (error.code == 'account_pending_deletion') {
          final pending = PendingDeletion.fromDetails(error.details);
          if (pending != null) {
            state = state.copyWith(
              busy: true,
              email: normalized,
              restore: pending,
            );
            outcome = LoginOutcome.needsRestore;
            return;
          }
        }
        if (error.code != 'email_not_verified') {
          rethrow;
        }
        state = state.copyWith(
          busy: true,
          email: normalized,
          registering: false,
        );
        outcome = LoginOutcome.needsVerification;
        return;
      }
      outcome = LoginOutcome.signedIn;
      _signedIn();
    });
    if (ok && outcome == LoginOutcome.needsVerification) {
      // A failed resend is shown on the code screen; the user can retry.
      await resendCode();
    }
    return ok ? outcome : LoginOutcome.failed;
  }

  /// Restores the account of the last login with the mailed [code]; true
  /// when signed in again (ADR 0010 §2).
  Future<bool> restoreAccount(String code) async {
    final pending = state.restore;
    final digits = code.trim();
    if (pending == null || _sessionActive) {
      state = state.copyWith(errorCode: AuthClientErrors.generic);
      return false;
    }
    if (!isWellFormedCode(digits)) {
      state = state.copyWith(errorCode: AuthClientErrors.invalidCode);
      return false;
    }
    return _run(() async {
      await ref.read(authApiProvider).restore(
            ticket: pending.restoreTicket,
            code: digits,
          );
      _signedIn();
    });
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
    } on Exception {
      // Anything else (storage, platform) is still reported, never left
      // spinning.
      state = state.copyWith(busy: false, errorCode: AuthClientErrors.generic);
      return false;
    }
  }
}
