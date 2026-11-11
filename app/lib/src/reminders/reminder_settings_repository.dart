import 'package:drift/drift.dart';
import 'package:pillpal_core/pillpal_core.dart' show defaultRepeatEveryMinutes;

import '../data/db/database.dart';
import 'reminder_settings.dart';

/// Device-local, app-wide reminder settings (TZ §2.3, redesign Q2). Writes
/// trigger a re-plan through the database's table updates (see
/// `ReminderController`).
class ReminderSettingsRepository {
  /// Creates the repository over [_db].
  ReminderSettingsRepository(this._db);

  static const int _defaultsRowId = 1;

  /// Not a medication id (those are UUIDs): the row that says the notice is
  /// pending.
  static const String _noticeMarkerId = '_level-migration-notice';

  static const MedicationReminderRow _noticeMarker = MedicationReminderRow(
    medicationId: _noticeMarkerId,
    level: 'normal',
    repeatEveryMinutes: defaultRepeatEveryMinutes,
    maxRepeats: defaultMaxRepeats,
    enabled: true,
  );

  final AppDatabase _db;

  /// The defaults (built-in until the user changes them).
  Future<ReminderSettings> defaults() async =>
      _fromDefaults(await _defaultsQuery().getSingleOrNull());

  /// The defaults and their changes.
  Stream<ReminderSettings> watchDefaults() =>
      _defaultsQuery().watchSingleOrNull().map(_fromDefaults);

  /// Replaces the defaults (the name-hiding setting stays as it is).
  Future<void> setDefaults(ReminderSettings settings) async {
    await _db
        .into(_db.reminderDefaults)
        .insertOnConflictUpdate(_defaultsCompanion(settings));
  }

  /// Whether reminders hide medication names and doses (device setting,
  /// off by default).
  Future<bool> hideMedicationNames() async =>
      (await _defaultsQuery().getSingleOrNull())?.hideMedicationNames ?? false;

  /// [hideMedicationNames] and its changes.
  Stream<bool> watchHideMedicationNames() => _defaultsQuery()
      .watchSingleOrNull()
      .map((row) => row?.hideMedicationNames ?? false);

  /// Turns name hiding on or off; the other defaults stay.
  Future<void> setHideMedicationNames({required bool hide}) async {
    await _db.into(_db.reminderDefaults).insert(
          _defaultsCompanion(ReminderSettings.builtIn)
              .copyWith(hideMedicationNames: Value(hide)),
          onConflict: DoUpdate(
            (_) => ReminderDefaultsCompanion(hideMedicationNames: Value(hide)),
          ),
        );
  }

  SimpleSelectStatement<$ReminderDefaultsTable, ReminderDefaultsRow>
      _defaultsQuery() => _db.select(_db.reminderDefaults)
        ..where((row) => row.id.equals(_defaultsRowId));

  ReminderDefaultsCompanion _defaultsCompanion(ReminderSettings settings) =>
      ReminderDefaultsCompanion(
        id: const Value(_defaultsRowId),
        level: Value(settings.level.name),
        repeatEveryMinutes: Value(settings.repeatEveryMinutes),
        maxRepeats: Value(settings.maxRepeats),
        enabled: Value(settings.enabled),
      );

  /// Turns the per-medication overrides of older versions into the one
  /// app-wide setting, then deletes them (redesign Q2).
  ///
  /// The new default is the most demanding of the old default and every
  /// override that is on (`mostDemanding`), so no reminder gets quieter or
  /// stops; when there was any override, the notice for Today is set once
  /// ([levelMigrationNotice]). Device-local, never synced. With nothing to
  /// migrate it does nothing, so it is safe to run on every start.
  Future<void> migrateLegacyOverrides() {
    return _db.transaction(() async {
      final rows = await (_db.select(_db.medicationReminderSettings)
            ..where((row) => row.medicationId.equals(_noticeMarkerId).not()))
          .get();
      if (rows.isEmpty) {
        return;
      }
      final merged = mostDemanding(
        await defaults(),
        [
          for (final row in rows)
            _settings(
              row.level,
              row.repeatEveryMinutes,
              row.maxRepeats,
              enabled: row.enabled,
            ),
        ],
      );
      await setDefaults(merged);
      await _db.delete(_db.medicationReminderSettings).go();
      await _db.into(_db.medicationReminderSettings).insert(_noticeMarker);
    });
  }

  /// Whether Today still has to tell the user that the reminder level is
  /// shared by all medications now. It is a marker row of the legacy table,
  /// which nothing else reads: a flag without a schema change.
  Future<bool> levelMigrationNotice() async =>
      (await _noticeQuery().getSingleOrNull()) != null;

  /// [levelMigrationNotice] and its changes.
  Stream<bool> watchLevelMigrationNotice() =>
      _noticeQuery().watchSingleOrNull().map((row) => row != null);

  /// The user has seen the notice.
  Future<void> dismissLevelMigrationNotice() async {
    await (_db.delete(_db.medicationReminderSettings)
          ..where((row) => row.medicationId.equals(_noticeMarkerId)))
        .go();
  }

  SimpleSelectStatement<$MedicationReminderSettingsTable, MedicationReminderRow>
      _noticeQuery() => _db.select(_db.medicationReminderSettings)
        ..where((row) => row.medicationId.equals(_noticeMarkerId));

  ReminderSettings _fromDefaults(ReminderDefaultsRow? row) {
    if (row == null) {
      return ReminderSettings.builtIn;
    }
    return _settings(
      row.level,
      row.repeatEveryMinutes,
      row.maxRepeats,
      enabled: row.enabled,
    );
  }

  /// Out-of-range stored values fall back to the built-in ones, so a bad
  /// row never stops reminders.
  ReminderSettings _settings(
    String level,
    int repeatEveryMinutes,
    int maxRepeats, {
    required bool enabled,
  }) {
    try {
      return ReminderSettings(
        level: reminderLevelFromName(level),
        repeatEveryMinutes: repeatEveryMinutes,
        maxRepeats: maxRepeats,
        enabled: enabled,
      );
    } on RangeError {
      return ReminderSettings.builtIn.copyWith(
        level: reminderLevelFromName(level),
        enabled: enabled,
      );
    }
  }
}
