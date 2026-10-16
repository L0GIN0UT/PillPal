import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/reminders/reminder_settings.dart';
import 'package:pillpal_core/pillpal_core.dart';

import 'reminder_test_env.dart';

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

  test('defaults and overrides round-trip and stream', () async {
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

    expect(await repository.watchOverride('m1').first, isNull);
    await repository.setOverride('m1', ReminderSettings(enabled: false));
    expect(
      await repository.watchOverride('m1').first,
      ReminderSettings(enabled: false),
    );
    expect(
        await repository.overrides(), {'m1': ReminderSettings(enabled: false)});

    await repository.clearOverride('m1');
    expect(await repository.overrides(), isEmpty);
  });

  test('a corrupt stored value falls back instead of failing', () async {
    final db = env.data.db;
    await db.into(db.medicationReminderSettings).insert(
          const MedicationReminderRow(
            medicationId: 'm1',
            level: 'persistent',
            repeatEveryMinutes: 0,
            maxRepeats: 3,
            enabled: true,
          ),
        );
    final settings = (await env.settings.overrides())['m1']!;
    expect(settings.level, ReminderLevel.persistent);
    expect(settings.repeatEveryMinutes, defaultRepeatEveryMinutes);
  });

  test('wiping account data drops medication settings and applied rows',
      () async {
    final db = env.data.db;
    await env.settings.setOverride('m1', ReminderSettings(enabled: false));
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

    expect(await env.settings.overrides(), isEmpty);
    // Device preferences stay; applied notifications reference the
    // account's medications and go with them.
    expect((await env.settings.defaults()).enabled, isFalse);
    expect(await db.select(db.appliedNotifications).get(), isEmpty);
  });
}
