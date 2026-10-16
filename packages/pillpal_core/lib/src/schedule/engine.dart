import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as timezone;

import 'local_date.dart';
import 'rule.dart';

/// The longest window [expand] accepts; callers page through longer ranges.
const Duration maxWindow = Duration(days: 400);

const int _msPerDay = Duration.millisecondsPerDay;

/// Nominal dates whose DST-shifted instant can fall into a window lie at most
/// this many days outside the window's local dates (spec section 4).
const int _dateMargin = 2;

/// UTC offset in milliseconds of a zone at an instant (ms since epoch).
typedef _OffsetAt = int Function(int millisecondsSinceEpoch);

bool _timeZonesInitialized = false;

/// Loads the full IANA database of `package:timezone` once.
///
/// [expand] and [localToUtc] call this themselves; it is public so that an
/// app can pay the start-up cost early. If the app already initialized the
/// database (for example to call `setLocalLocation` for notifications), it is
/// left untouched, because re-initializing resets `tz.local` to UTC. The app
/// must load the `latest_all` database: smaller variants lack history.
void ensureTimeZonesInitialized() {
  if (_timeZonesInitialized) {
    return;
  }
  if (!timezone.timeZoneDatabase.isInitialized) {
    tzdata.initializeTimeZones();
  }
  _timeZonesInitialized = true;
}

/// One scheduled dose.
///
/// [key], [localDate] and [localTime] are nominal (never DST-shifted);
/// [atUtc] is the instant, always in UTC.
class Occurrence {
  /// Creates an occurrence.
  const Occurrence({
    required this.key,
    required this.localDate,
    required this.localTime,
    required this.atUtc,
    required this.doseAmount,
    required this.doseUnit,
  });

  /// `{scheduleId}/{YYYY-MM-DD}T{HH:MM}`.
  final String key;

  /// Nominal local date.
  final LocalDate localDate;

  /// Nominal local time `HH:MM`.
  final String localTime;

  /// The instant of the dose (UTC).
  final DateTime atUtc;

  /// Normalised dose amount, e.g. `'0.5'`.
  final String doseAmount;

  /// Dose unit identifier, e.g. `'tablet'`.
  final String doseUnit;

  @override
  bool operator ==(Object other) =>
      other is Occurrence &&
      other.key == key &&
      other.localDate == localDate &&
      other.localTime == localTime &&
      other.atUtc == atUtc &&
      other.doseAmount == doseAmount &&
      other.doseUnit == doseUnit;

  @override
  int get hashCode =>
      Object.hash(key, localDate, localTime, atUtc, doseAmount, doseUnit);

  @override
  String toString() => 'Occurrence($key at $atUtc: $doseAmount $doseUnit)';
}

/// The occurrence key built from the nominal local date and time.
String occurrenceKey(String scheduleId, LocalDate localDate, String localTime) {
  return '$scheduleId/${localDate}T$localTime';
}

/// The instant of wall time [hour]:[minute] on [date] in zone [tzName].
///
/// A non-existent time (DST gap) is read with the UTC offset in effect before
/// the transition; an ambiguous time (overlap) maps to the earlier instant.
/// Throws [ArgumentError] for an unknown zone.
DateTime localToUtc(LocalDate date, int hour, int minute, String tzName) {
  return _toUtc(date, hour, minute, _offsetFunction(tzName));
}

/// All occurrences of [rule] whose instant lies in `[start, end)`.
///
/// [tz] is the effective IANA zone. [start] and [end] are compared as
/// instants. The result is sorted by instant, then key. Throws
/// [ArgumentError] for an empty [scheduleId], `end` before `start`, a window
/// longer than [maxWindow] or an unknown zone.
List<Occurrence> expand(
  ScheduleRule rule, {
  required String scheduleId,
  required String tz,
  required DateTime start,
  required DateTime end,
}) {
  if (scheduleId.isEmpty) {
    throw ArgumentError.value(scheduleId, 'scheduleId', 'Must not be empty');
  }
  if (end.isBefore(start)) {
    throw ArgumentError('end must not be before start');
  }
  if (end.difference(start) > maxWindow) {
    throw ArgumentError('The window must not exceed 400 days');
  }
  final offsetAt = _offsetFunction(tz);
  if (rule.kind == RuleKind.asNeeded || end.isAtSameMomentAs(start)) {
    return <Occurrence>[];
  }

  final startUs = start.microsecondsSinceEpoch;
  final endUs = end.microsecondsSinceEpoch;
  var first = _localDateOf(start, offsetAt).addDays(-_dateMargin);
  if (first.isBefore(rule.startDate)) {
    first = rule.startDate;
  }
  var last = _localDateOf(end, offsetAt).addDays(_dateMargin);
  final endDate = rule.endDate;
  if (endDate != null && endDate.isBefore(last)) {
    last = endDate;
  }

  final result = <Occurrence>[];
  for (var day = first; !day.isAfter(last); day = day.addDays(1)) {
    if (!rule.occursOn(day)) {
      continue;
    }
    for (final slot in rule.times) {
      final atUtc = _toUtc(day, slot.hour, slot.minute, offsetAt);
      final atUs = atUtc.microsecondsSinceEpoch;
      if (atUs < startUs || atUs >= endUs) {
        continue;
      }
      final occurrence = Occurrence(
        key: occurrenceKey(scheduleId, day, slot.time),
        localDate: day,
        localTime: slot.time,
        atUtc: atUtc,
        doseAmount: slot.dose.amount,
        doseUnit: slot.dose.unit.name,
      );
      result.add(occurrence);
    }
  }
  result.sort(_compareOccurrences);
  return result;
}

int _compareOccurrences(Occurrence a, Occurrence b) {
  final byInstant = a.atUtc.compareTo(b.atUtc);
  return byInstant != 0 ? byInstant : a.key.compareTo(b.key);
}

_OffsetAt _offsetFunction(String name) {
  ensureTimeZonesInitialized();
  final timezone.Location location;
  try {
    location = timezone.getLocation(name);
  } catch (_) {
    if (name == 'UTC') {
      return (int ms) => 0;
    }
    throw ArgumentError.value(name, 'tz', 'Unknown time zone');
  }
  // `translate` returns local wall-clock milliseconds as an int in every
  // supported version of package:timezone (TimeZone.offset changed type).
  return (int ms) => location.translate(ms) - ms;
}

LocalDate _localDateOf(DateTime instant, _OffsetAt offsetAt) {
  final ms = instant.millisecondsSinceEpoch;
  final localMs = ms + offsetAt(ms);
  final epochDay = (localMs - localMs % _msPerDay) ~/ _msPerDay;
  return LocalDate.fromEpochDay(epochDay);
}

/// Spec section 3.1, portable algorithm: assumes at most one offset
/// transition within 24 hours of the wall time.
DateTime _toUtc(LocalDate date, int hour, int minute, _OffsetAt offsetAt) {
  final wall = DateTime.utc(date.year, date.month, date.day, hour, minute);
  final wallMs = wall.millisecondsSinceEpoch;
  final before = offsetAt(wallMs - _msPerDay);
  final after = offsetAt(wallMs + _msPerDay);
  int? best;
  for (final offset in [before, after]) {
    final candidate = wallMs - offset;
    if (offsetAt(candidate) == offset && (best == null || candidate < best)) {
      best = candidate;
    }
  }
  final ms = best ?? wallMs - before;
  return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}
