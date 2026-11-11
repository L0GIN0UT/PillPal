import 'package:flutter/foundation.dart';
import 'package:pillpal_core/pillpal_core.dart';

/// Repeats after the first notification when the user has not chosen (M).
const int defaultMaxRepeats = 3;

/// Repeat intervals offered in the UI, in minutes (N).
const List<int> repeatIntervalChoices = [5, 10, 15, 30, 60];

/// Repeat counts offered in the UI (M).
const List<int> maxRepeatsChoices = [1, 2, 3, 5, 10];

/// How long the notification action "Snooze" postpones a dose.
const Duration notificationSnooze = Duration(minutes: 15);

/// The level stored as [ReminderLevel.name]; unknown values read as normal.
ReminderLevel reminderLevelFromName(String name) =>
    ReminderLevel.values.asNameMap()[name] ?? ReminderLevel.normal;

/// Whether a reminder for a medication with [privacy] may show its name
/// and dose: only `shared` ones, and only while the device setting
/// [hideMedicationNames] is off (ADR 0001 §8).
bool showsMedicationDetails(
  String privacy, {
  required bool hideMedicationNames,
}) =>
    privacy == 'shared' && !hideMedicationNames;

/// The most demanding of [defaults] and [overrides] that are on: the highest
/// level (quiet < normal < persistent < alarm), then the shortest repeat
/// interval, then the most repeats; N and M come from the chosen one. A
/// setting that is on beats one that is off, and when every one is off the
/// [defaults] stay. Used once, to turn the per-medication settings of older
/// versions into the single app-wide one without silencing anything.
ReminderSettings mostDemanding(
  ReminderSettings defaults,
  Iterable<ReminderSettings> overrides,
) {
  final on = [defaults, ...overrides].where((s) => s.enabled).toList();
  if (on.isEmpty) {
    return defaults;
  }
  return on.reduce((best, next) {
    if (next.level != best.level) {
      return next.level.index > best.level.index ? next : best;
    }
    if (next.repeatEveryMinutes != best.repeatEveryMinutes) {
      return next.repeatEveryMinutes < best.repeatEveryMinutes ? next : best;
    }
    return next.maxRepeats > best.maxRepeats ? next : best;
  });
}

/// How a medication reminds (TZ §2.3): level, repeats and on/off.
@immutable
class ReminderSettings {
  /// Creates settings; throws [RangeError] for N or M outside the planner's
  /// limits (`ReminderSource`).
  ReminderSettings({
    this.level = ReminderLevel.normal,
    this.repeatEveryMinutes = defaultRepeatEveryMinutes,
    this.maxRepeats = defaultMaxRepeats,
    this.enabled = true,
  }) {
    RangeError.checkValueInInterval(
      repeatEveryMinutes,
      minRepeatEveryMinutes,
      maxRepeatEveryMinutes,
      'repeatEveryMinutes',
    );
    RangeError.checkValueInInterval(
        maxRepeats, 0, maxRepeatsLimit, 'maxRepeats');
  }

  /// The built-in defaults: normal level, reminders on.
  static final ReminderSettings builtIn = ReminderSettings();

  /// Quiet, normal, persistent or alarm.
  final ReminderLevel level;

  /// N: minutes between repeats (persistent and alarm only).
  final int repeatEveryMinutes;

  /// M: repeats after the first notification (persistent and alarm only).
  final int maxRepeats;

  /// Whether reminders are on.
  final bool enabled;

  /// A copy with the given fields replaced.
  ReminderSettings copyWith({
    ReminderLevel? level,
    int? repeatEveryMinutes,
    int? maxRepeats,
    bool? enabled,
  }) {
    return ReminderSettings(
      level: level ?? this.level,
      repeatEveryMinutes: repeatEveryMinutes ?? this.repeatEveryMinutes,
      maxRepeats: maxRepeats ?? this.maxRepeats,
      enabled: enabled ?? this.enabled,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReminderSettings &&
      other.level == level &&
      other.repeatEveryMinutes == repeatEveryMinutes &&
      other.maxRepeats == maxRepeats &&
      other.enabled == enabled;

  @override
  int get hashCode =>
      Object.hash(level, repeatEveryMinutes, maxRepeats, enabled);

  @override
  String toString() => 'ReminderSettings(${level.name}, '
      'N: $repeatEveryMinutes, M: $maxRepeats, enabled: $enabled)';
}
