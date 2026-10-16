import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../data/db/database.dart';
import '../data/repositories/dose_events_repository.dart';
import 'fingerprints.dart';
import 'reminder_settings.dart';
import 'reminder_settings_repository.dart';

/// How far back dose events are read to find handled and snoozed
/// occurrences: covers the longest repeat span (N·M <= 25 days) and the
/// retention of applied notifications.
const Duration doseEventLookback = Duration(days: 30);

/// One enabled schedule ready for the planner, with what its notifications
/// show.
class ReminderTarget {
  /// Creates a target.
  const ReminderTarget({
    required this.source,
    required this.rule,
    required this.medicationName,
    required this.privacy,
    required this.scheduleFingerprint,
  });

  /// The planner input.
  final ReminderSource source;

  /// The parsed rule (dose of each time slot).
  final ScheduleRule rule;

  /// Medication name; shown only for `shared` medications.
  final String medicationName;

  /// `shared`, `anonymous` or `hidden`.
  final String privacy;

  /// See `scheduleFingerprint` in fingerprints.dart.
  final String scheduleFingerprint;
}

/// Handled and snoozed occurrences derived from dose events.
class OccurrenceStates {
  /// Creates states.
  const OccurrenceStates({required this.handled, required this.snoozedUntil});

  /// Keys with a `taken` or `skipped` event that was not undone.
  final Set<String> handled;

  /// Key -> `snooze_until` of its latest snooze that was not undone.
  final Map<String, DateTime> snoozedUntil;
}

/// Everything a re-plan reads from the database.
class ReminderInputs {
  /// Creates inputs.
  const ReminderInputs({
    required this.targets,
    required this.states,
    required this.fallbackTimeZone,
    this.hideMedicationNames = false,
  });

  /// Enabled schedules of live medications, by schedule id.
  final Map<String, ReminderTarget> targets;

  /// Handled and snoozed occurrences.
  final OccurrenceStates states;

  /// A profile's zone (`self` first), used when the device zone is unknown.
  final String? fallbackTimeZone;

  /// The device setting that makes every reminder generic.
  final bool hideMedicationNames;
}

/// Folds dose events into occurrence states (TZ §2.4): an `undo` cancels
/// its target; the latest remaining snooze of a key wins.
OccurrenceStates occurrenceStates(Iterable<DoseEventRow> events) {
  final sorted = events.toList()
    ..sort((a, b) {
      final byTime = a.at.compareTo(b.at);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
  final undone = {
    for (final event in sorted)
      if (event.eventType == DoseEventType.undo.wire) event.targetEventId,
  };
  final handled = <String>{};
  final snoozedUntil = <String, DateTime>{};
  for (final event in sorted) {
    final key = event.occurrenceKey;
    if (key == null || undone.contains(event.id)) {
      continue;
    }
    final type = event.eventType;
    final until = event.snoozeUntil;
    if (type == DoseEventType.taken.wire ||
        type == DoseEventType.skipped.wire) {
      handled.add(key);
    } else if (type == DoseEventType.snoozed.wire && until != null) {
      snoozedUntil[key] =
          DateTime.fromMicrosecondsSinceEpoch(until, isUtc: true);
    }
  }
  return OccurrenceStates(handled: handled, snoozedUntil: snoozedUntil);
}

/// Reads the reminder inputs from the local database.
class ReminderInputsLoader {
  /// Creates a loader.
  ReminderInputsLoader(this._db) : _settings = ReminderSettingsRepository(_db);

  final AppDatabase _db;
  final ReminderSettingsRepository _settings;

  /// Loads the inputs for a re-plan at [now].
  Future<ReminderInputs> load(DateTime now) async {
    return ReminderInputs(
      targets: await _targets(),
      states: await statesSince(now.subtract(doseEventLookback)),
      fallbackTimeZone: await _profileTimeZone(),
      hideMedicationNames: await _settings.hideMedicationNames(),
    );
  }

  /// Occurrence states from the events recorded since [since].
  Future<OccurrenceStates> statesSince(DateTime since) async {
    final micros = since.toUtc().microsecondsSinceEpoch;
    final events = await (_db.select(_db.doseEvents)
          ..where(
            (row) =>
                row.occurrenceKey.isNotNull() &
                row.at.isBiggerOrEqualValue(micros),
          ))
        .get();
    return occurrenceStates(events);
  }

  Future<Map<String, ReminderTarget>> _targets() async {
    final defaults = await _settings.defaults();
    final overrides = await _settings.overrides();
    final profiles = await (_db.select(_db.profiles)
          ..where((row) => row.deletedAt.isNull()))
        .map((row) => row.id)
        .get();
    final live = profiles.toSet();
    final medications = {
      for (final row in await (_db.select(_db.medications)
            ..where((row) => row.deletedAt.isNull()))
          .get())
        if (live.contains(row.profileId)) row.id: row,
    };
    final schedules = await (_db.select(_db.schedules)
          ..where((row) => row.deletedAt.isNull()))
        .get();
    final targets = <String, ReminderTarget>{};
    for (final schedule in schedules) {
      final medication = medications[schedule.medicationId];
      if (medication == null) {
        continue;
      }
      final settings = overrides[medication.id] ?? defaults;
      final target = _target(schedule, medication, settings);
      if (target != null) {
        targets[schedule.id] = target;
      }
    }
    return targets;
  }

  /// Null for a disabled or invalid schedule (a corrupt row must not stop
  /// the other reminders).
  ReminderTarget? _target(
    ScheduleRow schedule,
    MedicationRow medication,
    ReminderSettings settings,
  ) {
    if (!settings.enabled) {
      return null;
    }
    try {
      final rule = ScheduleRule.fromJson(jsonDecode(schedule.rule));
      final fixed = medication.tzMode == 'fixed';
      final source = ReminderSource(
        medicationId: medication.id,
        scheduleId: schedule.id,
        rule: rule,
        level: settings.level,
        tzMode: fixed ? TzMode.fixed : TzMode.local,
        fixedTz: fixed ? medication.fixedTz : null,
        repeatEveryMinutes: settings.repeatEveryMinutes,
        maxRepeats: settings.maxRepeats,
      );
      return ReminderTarget(
        source: source,
        rule: rule,
        medicationName: medication.name,
        privacy: medication.privacy,
        scheduleFingerprint: scheduleFingerprint(
          rule: rule,
          tzMode: medication.tzMode,
          fixedTz: medication.fixedTz,
          settings: settings,
          privacy: medication.privacy,
        ),
      );
    } on RuleValidationError {
      return null;
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  /// The `self` profile's zone, else any live profile's (managed profiles
  /// exist before the first sign-in pulls the `self` one).
  Future<String?> _profileTimeZone() async {
    final rows = await (_db.select(_db.profiles)
          ..where((row) => row.deletedAt.isNull())
          ..orderBy([(row) => OrderingTerm.asc(row.id)]))
        .get();
    for (final row in rows) {
      if (row.kind == 'self') {
        return row.timezone;
      }
    }
    return rows.isEmpty ? null : rows.first.timezone;
  }
}
