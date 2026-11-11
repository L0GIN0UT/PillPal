import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/reminders/reminder_settings.dart';
import 'package:pillpal_core/pillpal_core.dart';

import 'reminder_test_env.dart';

/// A row an older version wrote when a medication had its own settings.
Future<void> _legacyOverride(
  AppDatabase db,
  String medicationId, {
  String level = 'alarm',
  int every = 5,
  int repeats = 1,
  bool enabled = true,
}) =>
    db.into(db.medicationReminderSettings).insert(
          MedicationReminderRow(
            medicationId: medicationId,
            level: level,
            repeatEveryMinutes: every,
            maxRepeats: repeats,
            enabled: enabled,
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

  group('legacy per-medication overrides', () {
    final persistent30 = ReminderSettings(
      level: ReminderLevel.persistent,
      repeatEveryMinutes: 30,
      maxRepeats: 4,
    );

    Future<List<MedicationReminderRow>> rows() =>
        env.data.db.select(env.data.db.medicationReminderSettings).get();

    test('defaults off, one override on: reminders stay on at its level',
        () async {
      await env.settings.setDefaults(ReminderSettings(enabled: false));
      await _legacyOverride(env.data.db, 'm1', enabled: false);
      await _legacyOverride(
        env.data.db,
        'm2',
        level: 'persistent',
        every: 30,
        repeats: 4,
      );

      await env.settings.migrateLegacyOverrides();

      expect(await env.settings.defaults(), persistent30);
      expect(await env.settings.levelMigrationNotice(), isTrue);
      expect(await rows(), hasLength(1)); // only the notice marker
    });

    test('quieter overrides do not lower the default', () async {
      await env.settings.setDefaults(
        ReminderSettings(level: ReminderLevel.alarm, repeatEveryMinutes: 5),
      );
      await _legacyOverride(env.data.db, 'm1', level: 'quiet');
      await _legacyOverride(env.data.db, 'm2', level: 'normal');

      await env.settings.migrateLegacyOverrides();

      expect((await env.settings.defaults()).level, ReminderLevel.alarm);
      expect((await env.settings.defaults()).repeatEveryMinutes, 5);
    });

    test('only disabled overrides leave the enabled default as it is',
        () async {
      await env.settings.setDefaults(persistent30);
      await _legacyOverride(env.data.db, 'm1', level: 'alarm', enabled: false);

      await env.settings.migrateLegacyOverrides();

      expect(await env.settings.defaults(), persistent30);
    });

    test('the name-hiding device setting survives', () async {
      await env.settings.setHideMedicationNames(hide: true);
      await _legacyOverride(env.data.db, 'm1', level: 'alarm');

      await env.settings.migrateLegacyOverrides();

      expect(await env.settings.hideMedicationNames(), isTrue);
      expect((await env.settings.defaults()).level, ReminderLevel.alarm);
    });

    test('no overrides: nothing changes and there is no notice', () async {
      await env.settings.setDefaults(persistent30);

      await env.settings.migrateLegacyOverrides();

      expect(await env.settings.defaults(), persistent30);
      expect(await env.settings.levelMigrationNotice(), isFalse);
      expect(await rows(), isEmpty);
    });

    test('is idempotent and a dismissed notice stays dismissed', () async {
      await _legacyOverride(env.data.db, 'm1', level: 'alarm');
      await env.settings.migrateLegacyOverrides();
      await env.settings.migrateLegacyOverrides();
      expect(await env.settings.levelMigrationNotice(), isTrue);
      final migrated = await env.settings.defaults();

      await env.settings.dismissLevelMigrationNotice();
      await env.settings.migrateLegacyOverrides();

      expect(await env.settings.levelMigrationNotice(), isFalse);
      expect(await env.settings.defaults(), migrated);
      expect(await rows(), isEmpty);
    });

    test('mostDemanding: level, then interval, then repeats; on beats off', () {
      final quiet = ReminderSettings(level: ReminderLevel.quiet);
      final fast = ReminderSettings(
        level: ReminderLevel.persistent,
        repeatEveryMinutes: 5,
        maxRepeats: 2,
      );
      final slowMany = ReminderSettings(
        level: ReminderLevel.persistent,
        repeatEveryMinutes: 15,
        maxRepeats: 9,
      );
      expect(mostDemanding(quiet, [slowMany, fast]), fast);
      expect(mostDemanding(quiet, [slowMany, quiet]), slowMany);
      final off = ReminderSettings(enabled: false);
      expect(mostDemanding(off, [off]), off);
    });
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
