import 'package:drift/drift.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../data/db/database.dart';
import '../data/repositories/access_repository.dart';
import '../data/repositories/dose_event_mapping.dart';
import '../data/repositories/schedule_rows.dart';
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
class ReminderOccurrenceInputs {
  /// Creates states.
  const ReminderOccurrenceInputs({
    required this.handled,
    required this.snoozedUntil,
  });

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
  final ReminderOccurrenceInputs states;

  /// A profile's zone (`self` first), used when the device zone is unknown.
  final String? fallbackTimeZone;

  /// The device setting that makes every reminder generic.
  final bool hideMedicationNames;
}

/// Folds dose events into occurrence states (TZ §2.4): an `undo` cancels
/// its target; the latest remaining snooze of a key wins. The rule is the
/// shared dose-state contract (docs/spec/dose-state.md) in `pillpal_core`.
ReminderOccurrenceInputs reminderOccurrenceInputs(
  Iterable<DoseEventRow> events,
) {
  final handled = <String>{};
  final snoozedUntil = <String, DateTime>{};
  final states = occurrenceStatesByKey(doseEventsOf(events));
  for (final entry in states.entries) {
    if (entry.value.mark != null) {
      handled.add(entry.key);
    }
    final until = entry.value.snoozeUntil;
    if (until != null) {
      snoozedUntil[entry.key] = until;
    }
  }
  return ReminderOccurrenceInputs(
    handled: handled,
    snoozedUntil: snoozedUntil,
  );
}

/// A profile that may remind on this device and the zone its `local`
/// medications are read in.
class _RemindableProfile {
  const _RemindableProfile(this.timezone, {required this.followsDevice});

  /// `profiles.timezone`.
  final String timezone;

  /// Whether `local` medications follow the device zone: only the account's
  /// own `self` profile does (the phone is where that person is). Every
  /// other scope keeps its profile's zone, so grandma's 08:00 stays 08:00 in
  /// her zone on a guardian's phone elsewhere (D4, ADR 0007 §5).
  final bool followsDevice;
}

/// Reads the reminder inputs from the local database.
///
/// Reminders come only from profiles the account owns or guards (relatives
/// with a view never remind), that are not archived (D1), and, apart from
/// the own `self` profile, that this device reminds for: the per-device
/// switch (`profile_device_settings`) is on, or absent for a profile the
/// account owns - a new device or a re-login has no rows yet, and owned
/// profiles remind by default. A co-guardian's profile reminds only after
/// an explicit switch on (ADR 0005 §2).
class ReminderInputsLoader {
  /// Creates a loader.
  ReminderInputsLoader(this._db) : _settings = ReminderSettingsRepository(_db);

  final AppDatabase _db;
  final ReminderSettingsRepository _settings;

  /// Loads the inputs for a re-plan at [now].
  Future<ReminderInputs> load(DateTime now) async {
    final hide = await _settings.hideMedicationNames();
    final profiles = await _remindableProfiles();
    return ReminderInputs(
      targets: await _targets(profiles, hideMedicationNames: hide),
      states: await statesSince(now.subtract(doseEventLookback)),
      fallbackTimeZone: await _fallbackTimeZone(profiles),
      hideMedicationNames: hide,
    );
  }

  /// Occurrence states from the events recorded since [since].
  Future<ReminderOccurrenceInputs> statesSince(DateTime since) async {
    final micros = since.toUtc().microsecondsSinceEpoch;
    final events = await (_db.select(_db.doseEvents)
          ..where(
            (row) =>
                row.occurrenceKey.isNotNull() &
                row.at.isBiggerOrEqualValue(micros),
          ))
        .get();
    return reminderOccurrenceInputs(events);
  }

  /// Live, unarchived profiles of owner and guardian scopes that remind on
  /// this device, by profile id.
  Future<Map<String, _RemindableProfile>> _remindableProfiles() async {
    final query = _db.select(_db.profiles).join([
      innerJoin(
        _db.accessScopes,
        _db.accessScopes.profileId.equalsExp(_db.profiles.id),
      ),
    ])
      ..where(
        _db.profiles.deletedAt.isNull() &
            _db.accessScopes.archived.equals(false) &
            _db.accessScopes.role.isIn([ScopeRole.owner, ScopeRole.guardian]),
      );
    final rows = await query.get();
    final switches = {
      for (final row in await _db.select(_db.profileDeviceSettings).get())
        row.profileId: row.remindOnDevice,
    };
    final result = <String, _RemindableProfile>{};
    for (final row in rows) {
      final profile = row.readTable(_db.profiles);
      final scope = row.readTable(_db.accessScopes);
      final ownSelf = profile.kind == 'self' && scope.role == ScopeRole.owner;
      if (ownSelf ||
          ScopeRole.remindsByDefault(scope.role, switches[profile.id])) {
        result[profile.id] = _RemindableProfile(
          profile.timezone,
          followsDevice: ownSelf,
        );
      }
    }
    return result;
  }

  Future<Map<String, ReminderTarget>> _targets(
    Map<String, _RemindableProfile> profiles, {
    required bool hideMedicationNames,
  }) async {
    final defaults = await _settings.defaults();
    final overrides = await _settings.overrides();
    final liveMedications = await (_db.select(_db.medications)
          ..where(
            (row) => row.deletedAt.isNull() & row.redacted.equals(false),
          ))
        .get();
    final medications = {
      for (final row in liveMedications)
        if (profiles.containsKey(row.profileId)) row.id: row,
    };
    final schedules = await (_db.select(_db.schedules)
          ..where(
            (row) => row.deletedAt.isNull() & row.redacted.equals(false),
          ))
        .get();
    final targets = <String, ReminderTarget>{};
    for (final schedule in schedules) {
      final medication = medications[schedule.medicationId];
      if (medication == null) {
        continue;
      }
      final profile = profiles[medication.profileId];
      if (profile == null) {
        continue;
      }
      final target = _target(
        schedule,
        medication,
        overrides[medication.id] ?? defaults,
        profile,
        hideMedicationNames: hideMedicationNames,
      );
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
    _RemindableProfile profile, {
    required bool hideMedicationNames,
  }) {
    if (!settings.enabled) {
      return null;
    }
    try {
      final rule = parseScheduleRow(schedule);
      final fixedZone = medication.tzMode == 'fixed'
          ? medication.fixedTz
          : (profile.followsDevice ? null : profile.timezone);
      final fixed = fixedZone != null;
      final source = ReminderSource(
        medicationId: medication.id,
        scheduleId: schedule.id,
        rule: rule,
        level: settings.level,
        tzMode: fixed ? TzMode.fixed : TzMode.local,
        fixedTz: fixedZone,
        repeatEveryMinutes: settings.repeatEveryMinutes,
        maxRepeats: settings.maxRepeats,
      );
      return ReminderTarget(
        source: source,
        rule: rule,
        medicationName: medication.name ?? '',
        privacy: medication.privacy,
        scheduleFingerprint: scheduleFingerprint(
          rule: rule,
          tzMode: fixed ? 'fixed' : 'local',
          fixedTz: fixedZone,
          settings: settings,
          privacy: medication.privacy,
          namesShown: showsMedicationDetails(
            medication.privacy,
            hideMedicationNames: hideMedicationNames,
          ),
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

  /// The own `self` profile's zone, else any remindable profile's (managed
  /// profiles exist before the first sign-in pulls the `self` one).
  Future<String?> _fallbackTimeZone(
    Map<String, _RemindableProfile> profiles,
  ) async {
    final own = await AccessRepository(_db).ownSelfProfile();
    if (own != null) {
      return own.timezone;
    }
    final ids = profiles.keys.toList()..sort();
    return ids.isEmpty ? null : profiles[ids.first]?.timezone;
  }
}
