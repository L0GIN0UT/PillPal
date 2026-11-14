/// How often the invite QR panel refreshes (docs/adr/0020 §1–§2).
abstract final class InviteTiming {
  /// The countdown under the code redraws this often.
  static const Duration tick = Duration(seconds: 1);

  /// While the code is on screen, its state is asked this often: about 300
  /// cheap reads in a code's 15 minutes, and the owner learns of the scan
  /// within seconds without push.
  static const Duration poll = Duration(seconds: 3);
}

/// The time left on a code as `m:ss` (`h:mm:ss` from an hour on); never
/// negative.
String formatCountdown(Duration left) {
  final seconds = left.isNegative ? 0 : left.inSeconds;
  final hours = seconds ~/ Duration.secondsPerHour;
  final minutes =
      seconds ~/ Duration.secondsPerMinute % Duration.minutesPerHour;
  final rest = (seconds % Duration.secondsPerMinute).toString().padLeft(2, '0');
  if (hours == 0) {
    return '$minutes:$rest';
  }
  return '$hours:${minutes.toString().padLeft(2, '0')}:$rest';
}
