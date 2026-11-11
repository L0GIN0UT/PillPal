import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/reminders/reminder_settings.dart';
import 'package:pillpal_core/pillpal_core.dart';

import 'reminder_test_env.dart';

/// A row an older version wrote when a medication had its own settings.
Future<void> _legacyOverride(AppDatabase db, String medicationId) =>
    db.into(db.medicationReminderSettings).insert(
          MedicationReminderRow(
            medicationId: medicationId,
            level: 'alarm',
            repeatEveryMinutes: 5,
            maxRepeats: 1,
            enabled: false,
          ),
        );

void main() {
  late ReminderTestEnv env;

  setUp(() async => env = await ReminderTestEnv.create());
  tearDown(() => env.dispose());

  test('settings validate N and M like the planner', () {
    expect(() => ReminderSettings(repeatEveryMinutes: 0), throwsRangeError);
    expect(() => ReminderSettings(repeatEveryMinutes: 721), throwsRangeError);
    expect(() => ReminderSettings(maxRepeats: 51), throwsRangeError);
    expect(
      ReminderSettings.builtIn,
      ReminderSettings(level: ReminderLevel.normal, maxRepeats: 3),
    );
    expect(reminderLevelFromName('alarm'), ReminderLevel.alarm);
    expect(reminderLevelFromName('loud'), ReminderLevel.normal);
  });

  test('defaults round-trip and stream', () async {
    final repository = env.settings;
    expect(await repository.defaults(), ReminderSettings.builtIn);
    final defaults = repository.watchDefaults();
    final persistent = ReminderSettings(
      level: ReminderLevel.persistent,
      repeatEveryMinutes: 15,
      maxRepeats: 5,
    );

    await repository.setDefaults(persistent);
    expect(await defaults.first, persistent);
  });

  test('a corrupt stored default falls back instead of failing', () async {
    final db = env.data.db;
    await db.into(db.reminderDefaults).insert(
          const ReminderDefaultsRow(
            id: 1,
            level: 'persistent',
            repeatEveryMinutes: 0,
            maxRepeats: 3,
            enabled: true,
            hideMedicationNames: false,
          ),
        );
    final settings = await env.settings.defaults();
    expect(settings.level, ReminderLevel.persistent);
    expect(settings.repeatEveryMinutes, defaultRepeatEveryMinutes);
  });

  test('legacy per-medication overrides are cleared, defaults stay', () async {
    final db = env.data.db;
    await env.settings.setDefaults(ReminderSettings(enabled: false));
    await _legacyOverride(db, 'm1');
    await _legacyOverride(db, 'm2');

    await env.settings.clearLegacyOverrides();

    expect(await db.select(db.medicationReminderSettings).get(), isEmpty);
    expect((await env.settings.defaults()).enabled, isFalse);
    // Nothing to clear the second time.
    await env.settings.clearLegacyOverrides();
  });

  test('wiping account data drops medication settings and applied rows',
      () async {
    final db = env.data.db;
    await _legacyOverride(db, 'm1');
    await env.settings.setDefaults(ReminderSettings(enabled: false));
    await db.into(db.appliedNotifications).insert(
          const AppliedNotificationRow(
            id: 7,
            occurrenceKey: 'k',
            medicationId: 'm1',
            scheduleId: 's',
            fireAt: 0,
            repeatIndex: 0,
            level: 'normal',
            isSnooze: false,
            displayFingerprint: 'd',
            scheduleFingerprint: 's',
          ),
        );

    await db.wipeAccountData();

    expect(await db.select(db.medicationReminderSettings).get(), isEmpty);
    // Device preferences stay; applied notifications reference the
    // account's medications and go with them.
    expect((await env.settings.defaults()).enabled, isFalse);
    expect(await db.select(db.appliedNotifications).get(), isEmpty);
  });
}
