import 'package:drift/drift.dart';

// Local reminder state (milestone 2.3, docs/adr/0001-local-notifications.md).
// Never synced: reminder preferences belong to this device, and applied
// notifications mirror what this device's OS has pending or in its tray.

/// Device-wide reminder defaults; a single row with [id] 1, absent until
/// the user changes a default (built-in defaults apply then).
@DataClassName('ReminderDefaultsRow')
class ReminderDefaults extends Table {
  /// Always 1.
  IntColumn get id => integer()();

  /// `quiet`, `normal`, `persistent` or `alarm` (`ReminderLevel.name`).
  TextColumn get level => text()();

  /// N: minutes between repeats of repeating levels.
  IntColumn get repeatEveryMinutes => integer()();

  /// M: repeats after the first notification.
  IntColumn get maxRepeats => integer()();

  /// Whether medications without their own settings remind at all.
  BoolColumn get enabled => boolean()();

  /// Whether every reminder shows the generic text instead of the
  /// medication's name and dose (lock-screen privacy, ADR 0001 §8). A
  /// device setting: it survives sign-out.
  BoolColumn get hideMedicationNames =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Per-medication reminder settings; a row replaces the defaults for its
/// medication.
@DataClassName('MedicationReminderRow')
class MedicationReminderSettings extends Table {
  /// Medication id.
  TextColumn get medicationId => text()();

  /// `quiet`, `normal`, `persistent` or `alarm` (`ReminderLevel.name`).
  TextColumn get level => text()();

  /// N: minutes between repeats of repeating levels.
  IntColumn get repeatEveryMinutes => integer()();

  /// M: repeats after the first notification.
  IntColumn get maxRepeats => integer()();

  /// Whether this medication reminds at all.
  BoolColumn get enabled => boolean()();

  @override
  Set<Column<Object>> get primaryKey => {medicationId};
}

/// Notifications handed to the OS and not yet settled (pending, delayed or
/// in the tray), with the fingerprints they were applied with
/// (docs/spec/reminders.md §8). The OS cannot list fire times, so this is
/// the only record of what was scheduled.
@DataClassName('AppliedNotificationRow')
class AppliedNotifications extends Table {
  /// Platform notification id (`1..plannerIdMask`).
  IntColumn get id => integer()();

  /// Occurrence key `{schedule_id}/{YYYY-MM-DD}T{HH:MM}`.
  TextColumn get occurrenceKey => text()();

  /// Medication id.
  TextColumn get medicationId => text()();

  /// Schedule id.
  TextColumn get scheduleId => text()();

  /// Fire time, microseconds since epoch (UTC).
  IntColumn get fireAt => integer()();

  /// 0 for the first notification of a series.
  IntColumn get repeatIndex => integer()();

  /// `ReminderLevel.name`.
  TextColumn get level => text()();

  /// Whether it belongs to a snooze series.
  BoolColumn get isSnooze => boolean()();

  /// Opaque fingerprint of the presentation.
  TextColumn get displayFingerprint => text()();

  /// Opaque fingerprint of the schedule state it was planned from.
  TextColumn get scheduleFingerprint => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
