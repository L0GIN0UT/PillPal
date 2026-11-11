import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_exception.dart';
import '../../data/providers.dart';
import '../auth/auth_flow_state.dart';

/// Where the change of the password is.
enum ChangePasswordStep {
  /// The current password is asked for, to mail a code.
  current,

  /// The mailed code and the new password.
  code,

  /// The password is changed.
  done,
}

/// State of the change-password screen. The current password is never part
/// of it: the controller keeps it in memory only until the change ends.
@immutable
class ChangePasswordState {
  /// Creates a state.
  const ChangePasswordState({
    this.step = ChangePasswordStep.current,
    this.busy = false,
    this.errorCode,
    this.wiped = false,
    this.confirmFailures = 0,
  });

  /// Current step.
  final ChangePasswordStep step;

  /// A request is in flight.
  final bool busy;

  /// Error of the last action (server or [AuthClientErrors] code).
  final String? errorCode;

  /// The password was cleared while the app was in the background, so the
  /// first step asks for it again.
  final bool wiped;

  /// Confirmations the server refused so far.
  final int confirmFailures;

  /// Whether «Forgot password?» is offered.
  bool get offersReset =>
      confirmFailures >= AuthLimits.changeFailuresBeforeForgot;

  /// Copy with the given fields replaced; [errorCode] is cleared if omitted.
  ChangePasswordState copyWith({
    ChangePasswordStep? step,
    bool? busy,
    String? errorCode,
    bool? wiped,
    int? confirmFailures,
  }) {
    return ChangePasswordState(
      step: step ?? this.step,
      busy: busy ?? this.busy,
      errorCode: errorCode,
      wiped: wiped ?? this.wiped,
      confirmFailures: confirmFailures ?? this.confirmFailures,
    );
  }
}

/// Set once the password is changed, for the banner on Settings. It lives
/// while Settings is open.
final passwordChangedNoticeProvider = StateProvider.autoDispose<bool>(
  (ref) => false,
);

/// Drives the change-password screen: password -> mailed code -> new
/// password (`/v1/auth/password-change/*`). The session is kept: its
/// refresh token still works, so the next 401 refreshes silently.
///
/// A request in flight keeps the provider alive, so a screen closed meanwhile
/// cannot make it touch a disposed state; the password is wiped when the
/// request ends and nobody listens any more.
class ChangePasswordController
    extends AutoDisposeNotifier<ChangePasswordState> {
  String? _currentPassword;

  @override
  ChangePasswordState build() {
    ref.onDispose(wipe);
    return const ChangePasswordState();
  }

  /// Whether the current password is still held (tests).
  @visibleForTesting
  bool get holdsCurrentPassword => _currentPassword != null;

  /// Drops the reference to the current password: on success, when the
  /// screen goes away and when the app is in the background. The mailed code
  /// stays valid, so the user may fetch it from the mail app and come back;
  /// only a new code needs the password again.
  void wipe() {
    _currentPassword = null;
  }

  /// The app went to the background: [wipe], and say so on step 1 when the
  /// user had typed the password ([hadInput]).
  void backgrounded({required bool hadInput}) {
    wipe();
    if (hadInput && state.step == ChangePasswordStep.current) {
      state = state.copyWith(wiped: true);
    }
  }

  /// Clears a shown error (the user edits a field).
  void clearError() {
    if (state.errorCode != null) {
      state = state.copyWith();
    }
  }

  /// Checks [password] and mails a code; true when the code screen opens.
  Future<bool> requestCode(String password) {
    if (password.isEmpty) {
      state = state.copyWith(
        errorCode: AuthClientErrors.currentPasswordRequired,
      );
      return Future.value(false);
    }
    return _alive(() => _sendCode(password));
  }

  /// Mails a new code. Without the password (cleared in the background) it
  /// goes back to the first step instead, with a note.
  Future<bool> resend() {
    final password = _currentPassword;
    if (password == null) {
      state = state.copyWith(step: ChangePasswordStep.current, wiped: true);
      return Future.value(false);
    }
    return _alive(() => _sendCode(password));
  }

  /// Sets [newPassword] with the mailed [code]; true when it is changed.
  Future<bool> confirm({required String code, required String newPassword}) {
    final digits = code.trim();
    final invalid = isWellFormedCode(digits)
        ? validatePassword(newPassword)
        : AuthClientErrors.invalidCode;
    if (invalid != null) {
      state = state.copyWith(errorCode: invalid);
      return Future.value(false);
    }
    return _alive(() => _confirm(digits, newPassword));
  }

  /// Keeps the provider alive while [body] runs; the controller disposes
  /// (and wipes) afterwards if no screen listens.
  Future<bool> _alive(Future<bool> Function() body) async {
    final link = ref.keepAlive();
    try {
      return await body();
    } finally {
      link.close();
    }
  }

  Future<bool> _confirm(String digits, String newPassword) async {
    final changed = await _run(
      () => ref.read(authApiProvider).confirmPasswordChange(
            code: digits,
            newPassword: newPassword,
          ),
    );
    if (!changed) {
      final code = state.errorCode;
      final refused =
          code == ApiException.invalidCode || code == ApiException.rateLimited;
      if (refused) {
        state = state.copyWith(
          errorCode: code,
          confirmFailures: state.confirmFailures + 1,
        );
      }
      return false;
    }
    wipe();
    ref.read(passwordChangedNoticeProvider.notifier).state = true;
    state = state.copyWith(step: ChangePasswordStep.done);
    return true;
  }

  Future<bool> _sendCode(String password) async {
    final sent = await _run(
      () => ref.read(authApiProvider).requestPasswordChange(password),
    );
    if (sent) {
      _currentPassword = password;
      state = state.copyWith(step: ChangePasswordStep.code, wiped: false);
    }
    return sent;
  }

  Future<bool> _run(Future<void> Function() action) async {
    state = state.copyWith(busy: true);
    try {
      await action();
      state = state.copyWith(busy: false);
      return true;
    } on ApiException catch (error) {
      state = state.copyWith(busy: false, errorCode: _errorOf(error));
      return false;
    } on FormatException {
      state = state.copyWith(
        busy: false,
        errorCode: ApiException.invalidResponse,
      );
      return false;
    } on Exception {
      state = state.copyWith(busy: false, errorCode: AuthClientErrors.generic);
      return false;
    }
  }

  /// A refused token here means the session ended, not a restore failure.
  String _errorOf(ApiException error) => error.code == ApiException.invalidToken
      ? AuthClientErrors.sessionEnded
      : error.code;
}

/// The change-password controller.
final changePasswordProvider =
    NotifierProvider.autoDispose<ChangePasswordController, ChangePasswordState>(
  ChangePasswordController.new,
);
