import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/reminders/reminder_controller.dart';

import 'reminder_test_env.dart';

void main() {
  test('local writes trigger a re-plan: create, then take a dose', () async {
    final env = await ReminderTestEnv.create();
    addTearDown(env.dispose);
    final controller = ReminderController(
      db: env.data.db,
      service: env.service,
      clock: env.data.clock.call,
      locale: () => const Locale('en'),
      onOpenToday: () {},
      onSyncNeeded: () {},
      debounce: Duration.zero,
    );
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
}
