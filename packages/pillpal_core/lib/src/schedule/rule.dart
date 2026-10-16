import 'local_date.dart';

const int _ruleVersion = 1;
const int _minYear = 2000;
const int _maxYear = 2199;
const int _minIntervalDays = 2;
const int _maxIntervalDays = 366;
const int _maxSlots = 24;

const Set<String> _ruleKeys = {
  'v',
  'kind',
  'start_date',
  'end_date',
  'weekdays',
  'interval_days',
  'times',
};
const Set<String> _slotKeys = {'time', 'dose'};
const Set<String> _doseKeys = {'amount', 'unit'};

final RegExp _timePattern = RegExp(r'^([01][0-9]|2[0-3]):[0-5][0-9]$');
final RegExp _amountPattern = RegExp(r'^(0|[1-9][0-9]{0,5})(\.[0-9]{1,3})?$');
final RegExp _trailingZeros = RegExp(r'0+$');
final RegExp _trailingDot = RegExp(r'\.$');

/// Thrown by [ScheduleRule.fromJson] for a rule that violates the spec.
class RuleValidationError implements Exception {
  /// Creates an error with a human-readable [message].
  const RuleValidationError(this.message);

  /// What is wrong with the rule.
  final String message;

  @override
  String toString() => 'RuleValidationError: $message';
}

/// The kind of a schedule rule (docs/spec/schedule.md section 1.1).
enum RuleKind {
  /// Every day.
  daily('daily'),

  /// On the listed ISO weekdays.
  weekdays('weekdays'),

  /// Every N calendar days, anchored at the start date.
  intervalDays('interval_days'),

  /// No reminders; only manual dose events.
  asNeeded('as_needed');

  const RuleKind(this.wireName);

  /// Identifier used in the JSON document.
  final String wireName;
}

/// Dose units; [Enum.name] is the identifier used in JSON.
enum DoseUnit {
  tablet,
  capsule,
  ml,
  mg,
  drop,
  puff,
  sachet,
  unit,
  injection,
  other,
}

/// Validates a dose amount string and returns its normalised form.
///
/// `'0.50'` becomes `'0.5'`, `'2.000'` becomes `'2'`. Throws
/// [RuleValidationError] for anything that is not a positive decimal with at
/// most 6 integer and 3 fractional digits.
String normalizeAmount(String amount) {
  if (!_amountPattern.hasMatch(amount)) {
    throw RuleValidationError('Invalid dose amount "$amount"');
  }
  var result = amount;
  if (result.contains('.')) {
    result = result.replaceFirst(_trailingZeros, '');
    result = result.replaceFirst(_trailingDot, '');
  }
  if (result == '0') {
    throw const RuleValidationError('Dose amount must be greater than 0');
  }
  return result;
}

/// The dose taken at one time slot.
class Dose {
  const Dose._(this.amount, this.unit);

  factory Dose._fromJson(Object? json) {
    final map = _object(json, 'dose', _doseKeys);
    final amount = map['amount'];
    if (amount is! String) {
      throw const RuleValidationError('dose.amount must be a string');
    }
    final unit = DoseUnit.values.asNameMap()[map['unit']];
    if (unit == null) {
      throw RuleValidationError('Unknown dose unit "${map['unit']}"');
    }
    return Dose._(normalizeAmount(amount), unit);
  }

  /// Normalised decimal string, e.g. `'0.5'`.
  final String amount;

  /// Unit of [amount].
  final DoseUnit unit;

  /// Canonical JSON.
  Map<String, Object?> toJson() => {'amount': amount, 'unit': unit.name};
}

/// A time of day (local, `HH:MM`) with its dose.
class TimeSlot {
  const TimeSlot._(this.time, this.dose);

  factory TimeSlot._fromJson(Object? json) {
    final map = _object(json, 'time slot', _slotKeys);
    final time = map['time'];
    if (time is! String || !_timePattern.hasMatch(time)) {
      throw const RuleValidationError('time must be HH:MM (00:00..23:59)');
    }
    return TimeSlot._(time, Dose._fromJson(map['dose']));
  }

  /// Local wall-clock time `HH:MM`.
  final String time;

  /// Dose taken at [time].
  final Dose dose;

  /// Hour 0..23 of [time].
  int get hour => int.parse(time.substring(0, 2));

  /// Minute 0..59 of [time].
  int get minute => int.parse(time.substring(3));

  /// Canonical JSON.
  Map<String, Object?> toJson() => {'time': time, 'dose': dose.toJson()};
}

/// A validated, normalised schedule rule (`schedules.rule`, version 1).
///
/// See docs/spec/schedule.md. [weekdays] and [times] are sorted.
class ScheduleRule {
  ScheduleRule._({
    required this.kind,
    required this.startDate,
    required this.endDate,
    required this.weekdays,
    required this.intervalDays,
    required this.times,
  });

  /// Validates a decoded JSON document; throws [RuleValidationError].
  factory ScheduleRule.fromJson(Object? json) {
    final map = _object(json, 'rule', _ruleKeys);
    final version = map['v'];
    if (version is! int || version != _ruleVersion) {
      throw const RuleValidationError('v must be the integer 1');
    }
    final kind = _kind(map['kind']);
    final startDate = _date(map['start_date'], 'start_date');
    final rawEnd = map['end_date'];
    final endDate = rawEnd == null ? null : _date(rawEnd, 'end_date');
    final weekdays = _weekdays(map['weekdays']);
    final intervalDays = _intervalDays(map['interval_days']);
    final times = _times(map['times']);

    if (endDate != null && endDate.isBefore(startDate)) {
      throw const RuleValidationError('end_date is before start_date');
    }
    if ((kind == RuleKind.weekdays) != (weekdays != null)) {
      throw const RuleValidationError('weekdays: only for kind weekdays');
    }
    if ((kind == RuleKind.intervalDays) != (intervalDays != null)) {
      throw const RuleValidationError('interval_days: only for its kind');
    }
    if ((kind == RuleKind.asNeeded) != times.isEmpty) {
      throw const RuleValidationError('times: empty iff kind is as_needed');
    }
    return ScheduleRule._(
      kind: kind,
      startDate: startDate,
      endDate: endDate,
      weekdays: weekdays,
      intervalDays: intervalDays,
      times: times,
    );
  }

  /// Rule kind.
  final RuleKind kind;

  /// First local date of the schedule (inclusive).
  final LocalDate startDate;

  /// Last local date (inclusive), or null when open-ended.
  final LocalDate? endDate;

  /// Sorted ISO weekdays (Monday = 1) for [RuleKind.weekdays], else null.
  final List<int>? weekdays;

  /// N for [RuleKind.intervalDays], else null.
  final int? intervalDays;

  /// Time slots sorted by time; empty for [RuleKind.asNeeded].
  final List<TimeSlot> times;

  /// Whether the local calendar date [day] qualifies (spec section 2).
  bool occursOn(LocalDate day) {
    if (day.isBefore(startDate)) {
      return false;
    }
    final end = endDate;
    if (end != null && day.isAfter(end)) {
      return false;
    }
    switch (kind) {
      case RuleKind.daily:
        return true;
      case RuleKind.weekdays:
        return weekdays?.contains(day.weekday) ?? false;
      case RuleKind.intervalDays:
        return _isIntervalDay(day);
      case RuleKind.asNeeded:
        return false;
    }
  }

  bool _isIntervalDay(LocalDate day) {
    final n = intervalDays;
    if (n == null) {
      return false;
    }
    return (day.epochDay - startDate.epochDay) % n == 0;
  }

  /// Canonical JSON document (spec section 1.5).
  Map<String, Object?> toJson() {
    final days = weekdays;
    final interval = intervalDays;
    return {
      'v': _ruleVersion,
      'kind': kind.wireName,
      'start_date': startDate.toString(),
      'end_date': endDate?.toString(),
      if (days != null) 'weekdays': List<int>.of(days),
      if (interval != null) 'interval_days': interval,
      'times': [for (final slot in times) slot.toJson()],
    };
  }
}

Map<String, Object?> _object(Object? value, String what, Set<String> keys) {
  if (value is! Map<Object?, Object?>) {
    throw RuleValidationError('$what must be a JSON object');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String || !keys.contains(key)) {
      throw RuleValidationError('Unknown key "$key" in $what');
    }
    result[key] = entry.value;
  }
  return result;
}

RuleKind _kind(Object? value) {
  for (final kind in RuleKind.values) {
    if (kind.wireName == value) {
      return kind;
    }
  }
  throw RuleValidationError('Unknown kind "$value"');
}

LocalDate _date(Object? value, String field) {
  final date = value is String ? LocalDate.tryParse(value) : null;
  if (date == null || date.year < _minYear || date.year > _maxYear) {
    throw RuleValidationError('$field must be a date YYYY-MM-DD');
  }
  return date;
}

List<int>? _weekdays(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is! List<Object?> || value.isEmpty) {
    throw const RuleValidationError('weekdays must be a non-empty array');
  }
  final days = <int>{};
  for (final day in value) {
    if (day is! int || day < 1 || day > 7 || !days.add(day)) {
      throw const RuleValidationError('weekdays must be distinct 1..7');
    }
  }
  final sorted = days.toList()..sort();
  return List<int>.unmodifiable(sorted);
}

int? _intervalDays(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is! int || value < _minIntervalDays || value > _maxIntervalDays) {
    throw const RuleValidationError('interval_days must be 2..366');
  }
  return value;
}

List<TimeSlot> _times(Object? value) {
  if (value is! List<Object?>) {
    throw const RuleValidationError('times must be an array');
  }
  if (value.length > _maxSlots) {
    throw const RuleValidationError('At most 24 time slots are allowed');
  }
  final slots = <TimeSlot>[];
  final seen = <String>{};
  for (final item in value) {
    final slot = TimeSlot._fromJson(item);
    if (!seen.add(slot.time)) {
      throw RuleValidationError('Duplicate time ${slot.time}');
    }
    slots.add(slot);
  }
  slots.sort((a, b) => a.time.compareTo(b.time));
  return List<TimeSlot>.unmodifiable(slots);
}
