/// How often the invite QR panel refreshes (docs/adr/0020 §1–§2).
abstract final class InviteTiming {
  /// The countdown under the code redraws this often, and the panel checks
  /// whether the code ran out.
  static const Duration tick = Duration(seconds: 1);

  /// While the code is on screen (the app in front, the screen not covered),
  /// its state is asked this often: about 300 cheap reads in a code's 15
  /// minutes, and the owner learns of the scan within seconds without push.
  static const Duration poll = Duration(seconds: 3);
}

/// Whole minutes left, rounded up and at least 1: what the countdown and
/// the share message say («ещё 15 мин» right after creation).
int ceilMinutes(Duration left) {
  final seconds = left.isNegative ? 0 : left.inSeconds;
  final minutes =
      (seconds + Duration.secondsPerMinute - 1) ~/ Duration.secondsPerMinute;
  return minutes < 1 ? 1 : minutes;
}
