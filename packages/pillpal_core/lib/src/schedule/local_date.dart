/// A calendar date without a time of day or a time zone.
///
/// Uses the proleptic Gregorian calendar. Instances are immutable value
/// objects; [toString] returns `YYYY-MM-DD`.
class LocalDate implements Comparable<LocalDate> {
  /// Creates a date; throws [ArgumentError] if the date does not exist.
  factory LocalDate(int year, int month, int day) {
    final utc = DateTime.utc(year, month, day);
    if (utc.year != year || utc.month != month || utc.day != day) {
      throw ArgumentError('Invalid date: $year-$month-$day');
    }
    return LocalDate._(year, month, day);
  }

  /// The date [days] days after 1970-01-01 (negative values go back).
  factory LocalDate.fromEpochDay(int days) {
    final utc = DateTime.fromMillisecondsSinceEpoch(
      days * Duration.millisecondsPerDay,
      isUtc: true,
    );
    return LocalDate._(utc.year, utc.month, utc.day);
  }

  const LocalDate._(this.year, this.month, this.day);

  static final RegExp _pattern = RegExp(r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$');

  /// Parses `YYYY-MM-DD`; returns null if malformed or non-existent.
  static LocalDate? tryParse(String value) {
    final match = _pattern.firstMatch(value);
    if (match == null) {
      return null;
    }
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final utc = DateTime.utc(year, month, day);
    if (utc.year != year || utc.month != month || utc.day != day) {
      return null;
    }
    return LocalDate._(year, month, day);
  }

  /// Calendar year, e.g. 2026.
  final int year;

  /// Month 1..12.
  final int month;

  /// Day of month 1..31.
  final int day;

  /// Days since 1970-01-01.
  int get epochDay {
    final ms = DateTime.utc(year, month, day).millisecondsSinceEpoch;
    return ms ~/ Duration.millisecondsPerDay;
  }

  /// ISO weekday: Monday = 1 ... Sunday = 7.
  int get weekday => DateTime.utc(year, month, day).weekday;

  /// The date [days] calendar days later (earlier if negative).
  LocalDate addDays(int days) => LocalDate.fromEpochDay(epochDay + days);

  @override
  int compareTo(LocalDate other) {
    if (year != other.year) {
      return year.compareTo(other.year);
    }
    if (month != other.month) {
      return month.compareTo(other.month);
    }
    return day.compareTo(other.day);
  }

  /// Whether this date is strictly before [other].
  bool isBefore(LocalDate other) => compareTo(other) < 0;

  /// Whether this date is strictly after [other].
  bool isAfter(LocalDate other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is LocalDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() {
    final y = year.toString().padLeft(4, '0');
    final m = month.toString().padLeft(2, '0');
    final d = day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
