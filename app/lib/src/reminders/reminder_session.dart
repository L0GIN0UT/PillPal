import '../data/auth/access_claims.dart';
import '../data/auth/account_binding.dart';

/// Keeps reminders bound to the account like the local data (ADR 0002 §1).
///
/// Wraps the [AccountBinding]: whenever it erases the local data - an
/// explicit sign-out, or signing in as another account - every notification
/// of the app is cancelled, pending ones and the tray, and the applied
/// notifications are forgotten, so the previous account's reminders never
/// fire or stay visible for the next one. The home-screen widget is emptied
/// and the report PDFs left on the device are deleted as well; the push
/// provider gives its device token back, so the next account never receives
/// the previous one's alerts. A forced
/// sign-out (rejected refresh token) is not reported here and keeps all.
class ReminderSessionListener implements SessionListener {
  /// Creates the listener; [clearReminders] is `ReminderService.clearAll`.
  ReminderSessionListener({
    required AccountBinding binding,
    required Future<void> Function() clearReminders,
    Future<void> Function()? clearHomeWidget,
    Future<void> Function()? clearReportFiles,
    Future<void> Function()? clearPush,
  })  : _binding = binding,
        _clearers = [
          clearReminders,
          if (clearHomeWidget != null) clearHomeWidget,
          if (clearReportFiles != null) clearReportFiles,
          if (clearPush != null) clearPush,
        ];

  final AccountBinding _binding;
  final List<Future<void> Function()> _clearers;

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
    for (final clear in _clearers) {
      try {
        await clear();
      } on Object {
        // Intentionally silent, see above; the next clearer still runs.
      }
    }
  }
}
