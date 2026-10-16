import '../data/auth/access_claims.dart';
import '../data/auth/account_binding.dart';

/// Keeps reminders bound to the account like the local data (ADR 0002 §1).
///
/// Wraps the [AccountBinding]: whenever it erases the local data - an
/// explicit sign-out, or signing in as another account - every notification
/// of the app is cancelled, pending ones and the tray, and the applied
/// notifications are forgotten, so the previous account's reminders never
/// fire or stay visible for the next one. A forced sign-out (rejected
/// refresh token) is not reported here and keeps both.
class ReminderSessionListener implements SessionListener {
  /// Creates the listener; [clearReminders] is `ReminderService.clearAll`.
  ReminderSessionListener({
    required AccountBinding binding,
    required Future<void> Function() clearReminders,
  })  : _binding = binding,
        _clearReminders = clearReminders;

  final AccountBinding _binding;
  final Future<void> Function() _clearReminders;

  @override
  Future<void> signingIn(AccessClaims claims) async {
    if (await _binding.bind(claims)) {
      await _clear();
    }
  }

  @override
  Future<void> signedOut() async {
    await _binding.signedOut();
    await _clear();
  }

  /// Never fails the sign-in or sign-out: the data is already erased, and
  /// the next re-plan cancels stray pending notifications. Nothing is
  /// logged (errors may carry medical data).
  Future<void> _clear() async {
    try {
      await _clearReminders();
    } on Object {
      // Intentionally silent, see above.
    }
  }
}
