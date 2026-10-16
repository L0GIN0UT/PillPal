import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../data/providers.dart';

/// Reads the device's IANA zone; null when the platform reports none.
typedef TimeZoneReader = Future<String?> Function();

/// The device's IANA zone from the platform (`flutter_timezone`).
Future<String?> readPlatformTimeZone() async {
  try {
    return (await FlutterTimezone.getLocalTimezone()).identifier;
  } on Object {
    // No plugin (tests, unsupported platform) or no zone: unknown.
    return null;
  }
}

/// Source of the device zone; tests override it.
final timeZoneReaderProvider = Provider<TimeZoneReader>(
  (ref) => readPlatformTimeZone,
);

/// The device's IANA zone if the platform reports one the schedule engine
/// knows, else null. Invalidated on resume with [nowProvider] (the user may
/// have travelled).
final platformTimeZoneProvider = FutureProvider<String?>((ref) async {
  final name = await ref.watch(timeZoneReaderProvider)();
  return name != null && isKnownTimeZone(name) ? name : null;
});

/// IANA zone of the device, the effective zone of `tz_mode = local`
/// medications (docs/spec/schedule.md §3.1).
///
/// The platform zone; while it is being read or when it is unknown, a
/// fixed-offset zone derived from the current offset ([guessDeviceTimeZone]).
/// Registration sends only a platform zone (see `AuthFlowController`).
final deviceTimeZoneProvider = Provider<String>((ref) {
  final platform = ref.watch(platformTimeZoneProvider).valueOrNull;
  return platform ?? guessDeviceTimeZone(ref.watch(nowProvider).toLocal());
});

/// Whether the device zone has been read (screens wait for it so they do
/// not first render times in a guessed zone).
final deviceTimeZoneReadyProvider = Provider<bool>((ref) {
  final zone = ref.watch(platformTimeZoneProvider);
  return zone.hasValue || zone.hasError;
});

/// The current instant (UTC), cached until invalidated.
///
/// Screens that show time-dependent state (missed doses) invalidate it every
/// minute, so everything derived from it agrees on one "now" per frame.
final nowProvider = Provider<DateTime>((ref) => ref.watch(clockProvider)());

/// Today's local date in the device zone.
final todayDateProvider = Provider<LocalDate>(
  (ref) =>
      localDateOf(ref.watch(nowProvider), ref.watch(deviceTimeZoneProvider)),
);

/// Re-reads the clock and the device zone (on resume and pull-to-refresh).
void refreshNowAndZone(WidgetRef ref) {
  ref
    ..invalidate(nowProvider)
    ..invalidate(platformTimeZoneProvider);
}

/// A best-effort IANA zone for the local offset of [now] (a local time).
///
/// Uses the platform zone name when it already is an IANA name, otherwise
/// the `Etc/GMT` zone of a whole-hour offset (POSIX sign: `Etc/GMT-3` is
/// UTC+3), otherwise `UTC`.
String guessDeviceTimeZone(DateTime now) {
  final name = now.timeZoneName;
  if (name.contains('/') && isKnownTimeZone(name)) {
    return name;
  }
  final offset = now.timeZoneOffset;
  if (offset.inMinutes % Duration.minutesPerHour != 0) {
    return 'UTC';
  }
  final hours = offset.inHours;
  if (hours == 0) {
    return 'UTC';
  }
  final zone = hours > 0 ? 'Etc/GMT-$hours' : 'Etc/GMT+${-hours}';
  return isKnownTimeZone(zone) ? zone : 'UTC';
}

/// Whether the schedule engine knows the IANA zone [name].
bool isKnownTimeZone(String name) {
  if (name.trim().isEmpty) {
    return false;
  }
  try {
    localToUtc(LocalDate(2026, 1, 1), 0, 0, name);
    return true;
  } on ArgumentError {
    return false;
  }
}

/// A wall-clock reading in some zone.
class WallClock {
  /// Creates a reading.
  const WallClock(this.date, this.hour, this.minute);

  /// Local calendar date.
  final LocalDate date;

  /// Hour 0..23.
  final int hour;

  /// Minute 0..59.
  final int minute;

  /// `HH:MM`.
  String get hhmm =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

/// What a clock in [tz] shows at [instant] (minute precision).
///
/// Built on the engine's [localToUtc] so the app needs no second time-zone
/// library: the offset is refined until the wall time maps back to the
/// instant (two steps suffice outside DST transitions).
WallClock wallClockOf(DateTime instant, String tz) {
  final utc = instant.toUtc();
  // Minute precision: occurrences are whole minutes.
  final target =
      DateTime.utc(utc.year, utc.month, utc.day, utc.hour, utc.minute);
  var offset = Duration.zero;
  var wall = target;
  for (var step = 0; step < 3; step++) {
    wall = target.add(offset);
    final back = localToUtc(
      LocalDate(wall.year, wall.month, wall.day),
      wall.hour,
      wall.minute,
      tz,
    );
    if (back == target) {
      break;
    }
    offset += target.difference(back);
  }
  return WallClock(
    LocalDate(wall.year, wall.month, wall.day),
    wall.hour,
    wall.minute,
  );
}

/// The local date in [tz] at [instant].
LocalDate localDateOf(DateTime instant, String tz) =>
    wallClockOf(instant, tz).date;

/// The instants `[start, end)` of local [day] in [tz].
({DateTime start, DateTime end}) dayBounds(LocalDate day, String tz) {
  final start = localToUtc(day, 0, 0, tz);
  final end = localToUtc(day.addDays(1), 0, 0, tz);
  return (start: start, end: end);
}

/// First day of the month of [day].
LocalDate monthStart(LocalDate day) => LocalDate(day.year, day.month, 1);

/// First day of the month after the month of [day].
LocalDate nextMonthStart(LocalDate day) => day.month == 12
    ? LocalDate(day.year + 1, 1, 1)
    : LocalDate(day.year, day.month + 1, 1);

/// First day of the month before the month of [day].
LocalDate previousMonthStart(LocalDate day) => day.month == 1
    ? LocalDate(day.year - 1, 12, 1)
    : LocalDate(day.year, day.month - 1, 1);
