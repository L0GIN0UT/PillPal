import 'dart:async';
import 'dart:ui' show Locale;

import 'package:drift/drift.dart' show Value;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/reminders/flutter_notification_scheduler.dart';
import 'package:pillpal/src/reminders/reminder_controller.dart';
import 'package:pillpal/src/reminders/reminder_settings.dart';
import 'package:pillpal/src/reminders/reminder_settings_repository.dart';
import 'package:pillpal_core/pillpal_core.dart' show ReminderLevel;

import 'reminder_test_env.dart';

/// A plugin whose initialization fails (e.g. a platform exception).
class _BrokenPlatform extends FlutterNotificationScheduler {
  @override
  Future<void> initialize({
    required AppLocalizations strings,
    required DidReceiveNotificationResponseCallback onResponse,
    required DidReceiveBackgroundNotificationResponseCallback onBackground,
  }) async {
    throw StateError('plugin unavailable');
  }
}

/// A repository whose migration fails, like a locked database would.
class _FailingMigration extends ReminderSettingsRepository {
  _FailingMigration(ReminderTestEnv env) : super(env.data.db);

  @override
  Future<void> migrateLegacyOverrides() async => throw StateError('locked');
}

ReminderController _controller(
  ReminderTestEnv env, {
  FlutterNotificationScheduler? platform,
  void Function()? onReplanned,
  ReminderSettingsRepository? settings,
}) =>
    ReminderController(
      db: env.data.db,
      settings: settings ?? env.settings,
      service: env.service,
      clock: env.data.clock.call,
      locale: () => const Locale('en'),
      onOpenToday: () {},
      onSyncNeeded: () {},
      platform: platform,
      onReplanned: onReplanned,
      debounce: Duration.zero,
      retryDelay: const Duration(milliseconds: 10),
    );

void main() {
  test('starting migrates the per-medication overrides of older versions',
      () async {
    final env = await ReminderTestEnv.create();
    addTearDown(env.dispose);
    final ids = await env.seed();
    final db = env.data.db;
    await env.settings.setDefaults(ReminderSettings(enabled: false));
    await db.into(db.medicationReminderSettings).insert(
          MedicationReminderRow(
            medicationId: ids.medication,
            level: 'persistent',
            repeatEveryMinutes: 30,
            maxRepeats: 2,
            enabled: true,
          ),
        );
    final controller = _controller(env);
    addTearDown(controller.stop);

    await controller.start();

    // Reminders stay on, at the override's level, for every medication.
    expect(env.scheduler.pending, isNotEmpty);
    expect((await env.settings.defaults()).level, ReminderLevel.persistent);
    expect(await env.settings.levelMigrationNotice(), isTrue);
  });

  test('a failing migration does not stop the controller', () async {
    final env = await ReminderTestEnv.create();
    addTearDown(env.dispose);
    await env.seed();
    final controller = _controller(env, settings: _FailingMigration(env));
    addTearDown(controller.stop);

    await controller.start();

    expect(env.scheduler.pending, hasLength(2));
    // Still wired: a later write re-plans.
    final disabled = env.service.statusChanges
        .firstWhere((status) => status.planned == 0)
        .timeout(const Duration(seconds: 10));
    await env.settings.setDefaults(ReminderSettings(enabled: false));
    await disabled;
  });

  test('every re-plan is followed by onReplanned (home-screen widget)',
      () async {
    final env = await ReminderTestEnv.create();
    addTearDown(env.dispose);
    var calls = 0;
    final controller = _controller(env, onReplanned: () => calls++);
    addTearDown(controller.stop);
    await controller.start();
    expect(calls, 1);
    await controller.replanNow();
    expect(calls, 2);
  });

  test('local writes trigger a re-plan: create, then take a dose', () async {
    final env = await ReminderTestEnv.create();
    addTearDown(env.dispose);
    final controller = _controller(env);
    addTearDown(controller.stop);
    await controller.start();
    expect(env.service.status.planned, 0);

    final planned = env.service.statusChanges
        .firstWhere((status) => status.planned == 2)
        .timeout(const Duration(seconds: 10));
    final ids = await env.seed();
    await planned;
    expect(env.scheduler.pending, hasLength(2));

    final settled = env.service.statusChanges
        .firstWhere((status) => status.planned == 1)
        .timeout(const Duration(seconds: 10));
    await env.data.doseEvents.record(
      medicationId: ids.medication,
      type: DoseEventType.taken,
      at: env.data.clock.now,
      occurrence: env.occurrence(ids.schedule, 17),
    );
    await settled;
    expect(env.scheduler.pending, hasLength(1));

    final disabled = env.service.statusChanges
        .firstWhere((status) => status.planned == 0)
        .timeout(const Duration(seconds: 10));
    await env.settings.setDefaults(
      (await env.settings.defaults()).copyWith(enabled: false),
    );
    await disabled;
    expect(env.scheduler.pending, isEmpty);
  });

  test('pull bookkeeping of a scope does not re-plan; its archive state does',
      () async {
    final env = await ReminderTestEnv.create();
    addTearDown(env.dispose);
    final ids = await env.seed();
    var calls = 0;
    final second = Completer<void>();
    final controller = _controller(
      env,
      onReplanned: () {
        calls++;
        if (calls == 2 && !second.isCompleted) {
          second.complete();
        }
      },
    );
    addTearDown(controller.stop);
    await controller.start();
    await pumpEventQueue();
    expect(calls, 1);
    final scopes = env.data.db.update(env.data.db.accessScopes)
      ..where((row) => row.profileId.equals(ids.profile));

    // What each pulled page writes: cursor and pull time.
    await scopes.write(
      const AccessScopesCompanion(cursor: Value(9), lastPulledAt: Value(1)),
    );
    await pumpEventQueue();
    expect(calls, 1);

    await scopes.write(const AccessScopesCompanion(archived: Value(true)));
    await second.future.timeout(const Duration(seconds: 10));
    await pumpEventQueue();
    expect(calls, 2);
  });

  test('a failed re-plan is retried until it succeeds', () async {
    final env = await ReminderTestEnv.create();
    addTearDown(env.dispose);
    await env.seed();
    env.scheduler.failNextSchedules = 3;
    final controller = _controller(env);
    addTearDown(controller.stop);

    final recovered = env.service.statusChanges
        .firstWhere((status) => !status.failed && status.planned == 2)
        .timeout(const Duration(seconds: 10));
    await controller.start();
    expect(env.service.status.failed, isTrue);
    await recovered;

    expect(env.scheduler.pending, hasLength(2));
    expect(env.scheduler.failNextSchedules, 0);
  });

  test('a plugin that fails to initialize does not stop reminders', () async {
    final env = await ReminderTestEnv.create();
    addTearDown(env.dispose);
    await env.seed();
    final controller = _controller(env, platform: _BrokenPlatform());
    addTearDown(controller.stop);

    await controller.start();

    expect(env.service.status.planned, 2);
    expect(env.scheduler.pending, hasLength(2));
  });
}
