import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/clock.dart';
import 'package:pillpal/src/reminders/background_handler.dart';
import 'package:pillpal/src/reminders/reminder_actions.dart';
import 'package:pillpal/src/reminders/reminder_payload.dart';

import '../data/fake_server.dart';
import 'reminder_test_env.dart';

// ADR 0016 §5: a missing health data consent pauses the medical sync, never
// the reminders: they run from the local data, with or without the server.

void main() {
  late ReminderTestEnv env;
  late ({String profile, String medication, String schedule}) ids;

  setUp(() async {
    env = await ReminderTestEnv.create();
    ids = await env.seed();
    // Paused: the account lacks the health data consent.
    await env.data.syncState.bindAccount(FakeServer.defaultUserId, 'ru');
    await env.data.syncState.saveConsentMissing(
      FakeServer.defaultUserId,
      ['health_data', 'terms', 'privacy'],
    );
  });
  tearDown(() => env.dispose());

  test('the reminders are still planned from the local data', () async {
    await env.service.replan();

    expect(env.scheduler.pending, isNotEmpty);
    expect(
      env.scheduler.byTime.map(ReminderTestEnv.keyOf),
      contains(env.occurrence(ids.schedule, 17).key),
    );
    expect(env.data.server.requests, isEmpty, reason: 'no request at all');
  });

  test('"Taken" from the shade records the dose and queues it unsent',
      () async {
    await env.service.replan();
    // The 08:00 reminder of Oct 17 has fired; the user taps «Taken».
    env.data.clock.now = DateTime.utc(2026, 10, 17, 4, 2);
    final payload = ReminderPayload(
      occurrenceKey: env.occurrence(ids.schedule, 17).key,
      medicationId: ids.medication,
    );
    final outboxBefore = (await env.data.outbox()).length;

    final outcome = await runReminderAction(
      db: env.data.db,
      action: ReminderAction.fromResponse(
        actionId: 'taken',
        payload: payload.encode(),
      )!,
      scheduler: env.scheduler,
      clock: env.data.clock.call,
      newId: newUuid,
      deviceTimeZone: () async => 'Europe/Samara',
      locale: () => const Locale('en'),
      budget: 400,
      mainIsolateReplans: () async => false,
    );

    expect(outcome, ReminderActionOutcome.recorded);
    final events = await env.data.db.select(env.data.db.doseEvents).get();
    expect([for (final event in events) event.eventType], ['taken']);
    final outbox = await env.data.outbox();
    expect(outbox.length, outboxBefore + 1);
    expect(outbox.last.entityKind, 'dose_event');
    expect(outbox.last.parked, isFalse);
    expect(env.data.server.requests, isEmpty);
  });
}
