import '../schedule/rule.dart';

/// Smallest allowed repeat interval of repeating levels, in minutes.
const int minRepeatEveryMinutes = 1;

/// Largest allowed repeat interval of repeating levels, in minutes.
const int maxRepeatEveryMinutes = 720;

/// Repeat interval used when a source does not specify one, in minutes.
const int defaultRepeatEveryMinutes = 10;

/// Largest allowed number of repeats after the first notification.
const int maxRepeatsLimit = 50;

/// How insistent the reminders of a medication are (TZ §2.3).
enum ReminderLevel {
  /// One silent notification per occurrence.
  quiet,

  /// One notification with sound per occurrence.
  normal,

  /// Repeats every N minutes until marked, at most M times.
  persistent,

  /// Like [persistent], delivered through the alarm channel.
  alarm;

  /// Whether this level repeats (docs/spec/reminders.md §1.1).
  bool get repeats => this == persistent || this == alarm;
}

/// Which zone the times of a schedule are read in (TZ §2.2).
enum TzMode {
  /// The device's current zone: reminders follow the wall clock.
  local,

  /// The medication's pinned zone: intervals are kept exactly.
  fixed,
}

/// One schedule as seen by the reminder planner.
///
/// Throws [ArgumentError] for empty ids, a missing [fixedTz] in
/// [TzMode.fixed], or repeat settings outside
/// [minRepeatEveryMinutes]..[maxRepeatEveryMinutes] and 0..[maxRepeatsLimit].
class ReminderSource {
  /// Creates a validated source.
  ReminderSource({
    required this.medicationId,
    required this.scheduleId,
    required this.rule,
    required this.level,
    this.tzMode = TzMode.local,
    this.fixedTz,
    this.repeatEveryMinutes = defaultRepeatEveryMinutes,
    this.maxRepeats = 0,
    this.enabled = true,
  }) {
    _requireNonEmpty(medicationId, 'medicationId');
    _requireNonEmpty(scheduleId, 'scheduleId');
    final zone = fixedTz;
    if (tzMode == TzMode.fixed && (zone == null || zone.isEmpty)) {
      throw ArgumentError.value(zone, 'fixedTz', 'Required for fixed mode');
    }
    if (repeatEveryMinutes < minRepeatEveryMinutes ||
        repeatEveryMinutes > maxRepeatEveryMinutes) {
      throw RangeError.range(
        repeatEveryMinutes,
        minRepeatEveryMinutes,
        maxRepeatEveryMinutes,
        'repeatEveryMinutes',
      );
    }
    if (maxRepeats < 0 || maxRepeats > maxRepeatsLimit) {
      throw RangeError.range(maxRepeats, 0, maxRepeatsLimit, 'maxRepeats');
    }
  }

  /// Opaque medication id (canonical lowercase UUID).
  final String medicationId;

  /// Opaque schedule id (canonical lowercase UUID), unique per plan.
  final String scheduleId;

  /// The validated schedule rule.
  final ScheduleRule rule;

  /// Reminder level of the medication.
  final ReminderLevel level;

  /// Whether times follow the device zone or [fixedTz].
  final TzMode tzMode;

  /// IANA zone for [TzMode.fixed]; ignored for [TzMode.local].
  final String? fixedTz;

  /// N: minutes between repeats (repeating levels only).
  final int repeatEveryMinutes;

  /// M: repeats after the first notification (repeating levels only).
  final int maxRepeats;

  /// Disabled sources produce no notifications.
  final bool enabled;

  /// Repeats actually planned: [maxRepeats] for repeating levels, else 0.
  int get effectiveRepeats => level.repeats ? maxRepeats : 0;

  /// The zone the rule is expanded in for a device in [deviceTz].
  String effectiveTz(String deviceTz) {
    final fixed = fixedTz;
    return tzMode == TzMode.fixed && fixed != null ? fixed : deviceTz;
  }
}

void _requireNonEmpty(String value, String name) {
  if (value.isEmpty) {
    throw ArgumentError.value(value, name, 'Must not be empty');
  }
}
