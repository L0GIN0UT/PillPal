import '../data/db/database.dart';
import 'reminder_settings.dart';

/// Device-local reminder settings: global defaults and per-medication
/// overrides (TZ §2.3). Writes trigger a re-plan through the database's
/// table updates (see `ReminderController`).
class ReminderSettingsRepository {
  /// Creates the repository over [_db].
  ReminderSettingsRepository(this._db);

  static const int _defaultsRowId = 1;

  final AppDatabase _db;

  /// The defaults (built-in until the user changes them).
  Future<ReminderSettings> defaults() async => _fromDefaults(
        await (_db.select(_db.reminderDefaults)
              ..where((row) => row.id.equals(_defaultsRowId)))
            .getSingleOrNull(),
      );

  /// The defaults and their changes.
  Stream<ReminderSettings> watchDefaults() {
    return (_db.select(_db.reminderDefaults)
          ..where((row) => row.id.equals(_defaultsRowId)))
        .watchSingleOrNull()
        .map(_fromDefaults);
  }

  /// Replaces the defaults.
  Future<void> setDefaults(ReminderSettings settings) async {
    await _db.into(_db.reminderDefaults).insertOnConflictUpdate(
          ReminderDefaultsRow(
            id: _defaultsRowId,
            level: settings.level.name,
            repeatEveryMinutes: settings.repeatEveryMinutes,
            maxRepeats: settings.maxRepeats,
            enabled: settings.enabled,
          ),
        );
  }

  /// The settings of [medicationId], or null when it follows the defaults.
  Stream<ReminderSettings?> watchOverride(String medicationId) {
    return (_db.select(_db.medicationReminderSettings)
          ..where((row) => row.medicationId.equals(medicationId)))
        .watchSingleOrNull()
        .map((row) => row == null ? null : _fromOverride(row));
  }

  /// Gives [medicationId] its own [settings].
  Future<void> setOverride(String medicationId, ReminderSettings settings) {
    return _db.into(_db.medicationReminderSettings).insertOnConflictUpdate(
          MedicationReminderRow(
            medicationId: medicationId,
            level: settings.level.name,
            repeatEveryMinutes: settings.repeatEveryMinutes,
            maxRepeats: settings.maxRepeats,
            enabled: settings.enabled,
          ),
        );
  }

  /// Makes [medicationId] follow the defaults again.
  Future<void> clearOverride(String medicationId) async {
    await (_db.delete(_db.medicationReminderSettings)
          ..where((row) => row.medicationId.equals(medicationId)))
        .go();
  }

  /// Every override, by medication id.
  Future<Map<String, ReminderSettings>> overrides() async {
    final rows = await _db.select(_db.medicationReminderSettings).get();
    return {for (final row in rows) row.medicationId: _fromOverride(row)};
  }

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

  ReminderSettings _fromOverride(MedicationReminderRow row) => _settings(
        row.level,
        row.repeatEveryMinutes,
        row.maxRepeats,
        enabled: row.enabled,
      );

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
