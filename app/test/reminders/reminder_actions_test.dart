import 'dart:isolate';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/clock.dart';
import 'package:pillpal/src/reminders/background_handler.dart';
import 'package:pillpal/src/reminders/notification_scheduler.dart';
import 'package:pillpal/src/reminders/reminder_actions.dart';
import 'package:pillpal/src/reminders/reminder_payload.dart';

import 'reminder_test_env.dart';

void main() {
  late ReminderTestEnv env;
  late ({String profile, String medication, String schedule}) ids;
  late ReminderPayload payload;

  setUp(() async {
    env = await ReminderTestEnv.create();
    ids = await env.seed();
    payload = ReminderPayload(
      occurrenceKey: env.occurrence(ids.schedule, 17).key,
      medicationId: ids.medication,
    );
    await env.service.replan();
    // The 08:00 reminder of Oct 17 has fired; the user acts on it.
    env.data.clock.now = DateTime.utc(2026, 10, 17, 4, 2);
  });
  tearDown(() => env.dispose());

  Future<ReminderActionOutcome> act(
    String actionId, {
    bool mainIsolateRunning = false,
  }) {
    final action = ReminderAction.fromResponse(
      actionId: actionId,
      payload: payload.encode(),
    );
    return runReminderAction(
      db: env.data.db,
      action: action!,
      scheduler: env.scheduler,
      clock: env.data.clock.call,
      newId: newUuid,
      deviceTimeZone: () async => 'Europe/Samara',
      locale: () => const Locale('en'),
      budget: 400,
      mainIsolateReplans: () async => mainIsolateRunning,
    );
  }

  Future<List<String>> eventTypes() async {
    final rows = await env.data.db.select(env.data.db.doseEvents).get();
    return [for (final row in rows) row.eventType];
  }

  group('ReminderAction.fromResponse', () {
    test('maps the three actions and rejects anything else', () {
      final raw = payload.encode();
      expect(
        ReminderAction.fromResponse(actionId: 'taken', payload: raw)!.kind,
        ReminderActionKind.taken,
      );
      expect(
        ReminderAction.fromResponse(actionId: 'snooze', payload: raw)!.kind,
        ReminderActionKind.snooze,
      );
      expect(
        ReminderAction.fromResponse(actionId: 'skip', payload: raw)!.kind,
        ReminderActionKind.skip,
      );
      // A plain tap, an unknown action, foreign or broken payloads.
      expect(ReminderAction.fromResponse(actionId: null, payload: raw), isNull);
      expect(ReminderAction.fromResponse(actionId: 'x', payload: raw), isNull);
      for (final bad in [null, '', '{', '[]', '{"k":"a/b","m":"m"}']) {
        expect(
          ReminderAction.fromResponse(actionId: 'taken', payload: bad),
          isNull,
          reason: bad,
        );
      }
    });

    test('payload holds only the key and the medication id', () {
      expect(
        payload.encode(),
        '{"k":"${payload.occurrenceKey}","m":"${ids.medication}"}',
      );
      expect(ReminderPayload.tryDecode(payload.encode()), payload);
    });
  });

  test('taken records one event with a fresh UUID and clears the tray',
      () async {
    final notification = env.scheduler.scheduled
        .firstWhere((r) => ReminderTestEnv.keyOf(r) == payload.occurrenceKey)
        .id;
    env.scheduler.clearLog();

    expect(await act(ReminderActionIds.taken), ReminderActionOutcome.recorded);

    final rows = await env.data.db.select(env.data.db.doseEvents).get();
    expect(rows.single.eventType, 'taken');
    expect(rows.single.occurrenceKey, payload.occurrenceKey);
    expect(rows.single.at, env.data.clock.now.microsecondsSinceEpoch);
    expect(
      RegExp(r'^[0-9a-f-]{36}$').hasMatch(rows.single.id),
      isTrue,
    );
    final outbox = await env.data.outbox();
    expect(outbox.where((e) => e.entityKind == 'dose_event'), hasLength(1));
    expect(env.scheduler.cancelled, [notification]);

    // A second tap (another notification of the occurrence) is ignored.
    expect(
      await act(ReminderActionIds.taken),
      ReminderActionOutcome.alreadyHandled,
    );
    expect(
      await act(ReminderActionIds.skip),
      ReminderActionOutcome.alreadyHandled,
    );
    expect(await eventTypes(), ['taken']);
  });

  test('two simultaneous taps record exactly one event', () async {
    final action = ReminderAction.fromResponse(
      actionId: ReminderActionIds.taken,
      payload: payload.encode(),
    )!;
    ReminderActionHandler handler() => ReminderActionHandler(
          db: env.data.db,
          clock: env.data.clock.call,
          newId: newUuid,
        );

    final outcomes = await Future.wait([
      handler().handle(action),
      handler().handle(action),
    ]);

    expect(
      outcomes.toSet(),
      {ReminderActionOutcome.recorded, ReminderActionOutcome.alreadyHandled},
    );
    expect(await eventTypes(), ['taken']);
    final outbox = await env.data.outbox();
    expect(outbox.where((e) => e.entityKind == 'dose_event'), hasLength(1));
  });

  test('with the main isolate running only the event is written', () async {
    env.scheduler.clearLog();

    expect(
      await act(ReminderActionIds.taken, mainIsolateRunning: true),
      ReminderActionOutcome.recorded,
    );

    expect(await eventTypes(), ['taken']);
    // The main isolate re-plans; the background one touches nothing.
    expect(env.scheduler.calls, isEmpty);
  });

  group('handOverToMainIsolate', () {
    test('no registered port: re-plan in the background', () async {
      expect(await handOverToMainIsolate(null), isFalse);
    });

    test('a live main isolate answers and takes over', () async {
      final mainPort = ReceivePort();
      addTearDown(mainPort.close);
      var notified = 0;
      mainPort.listen((message) => answerBackgroundMessage(message, () {
            notified++;
          }));

      expect(await handOverToMainIsolate(mainPort.sendPort), isTrue);
      expect(notified, 1);
    });

    test('a stale registration does not answer: re-plan here', () async {
      final stale = ReceivePort();
      addTearDown(stale.close);

      expect(
        await handOverToMainIsolate(
          stale.sendPort,
          timeout: const Duration(milliseconds: 50),
        ),
        isFalse,
      );
    });

    test('the main isolate ignores foreign messages', () {
      var notified = 0;
      answerBackgroundMessage('x', () => notified++);
      answerBackgroundMessage([doseEventRecordedMessage], () => notified++);
      expect(notified, 0);
    });
  });

  test('skip records a skipped event', () async {
    expect(await act(ReminderActionIds.skip), ReminderActionOutcome.recorded);
    expect(await eventTypes(), ['skipped']);
  });

  test('snooze records snooze_until and schedules the snooze', () async {
    env.scheduler.clearLog();

    expect(await act(ReminderActionIds.snooze), ReminderActionOutcome.recorded);

    final row = (await env.data.db.select(env.data.db.doseEvents).get()).single;
    final until = DateTime.utc(2026, 10, 17, 4, 17);
    expect(row.eventType, 'snoozed');
    expect(row.snoozeUntil, until.microsecondsSinceEpoch);
    final snoozed = env.scheduler.scheduled
        .where((r) => ReminderTestEnv.keyOf(r) == payload.occurrenceKey)
        .single;
    expect(snoozed.fireAtUtc, until);

    // Snoozing again is a new event with its own id (no conflict).
    env.data.clock.now = DateTime.utc(2026, 10, 17, 4, 20);
    expect(await act(ReminderActionIds.snooze), ReminderActionOutcome.recorded);
    final rows = await env.data.db.select(env.data.db.doseEvents).get();
    expect(rows.map((r) => r.id).toSet(), hasLength(2));
  });

  test('an unknown medication is rejected without a write', () async {
    payload = ReminderPayload(
      occurrenceKey: payload.occurrenceKey,
      medicationId: '0f000000-0000-4000-8000-0000000000ff',
    );

    expect(await act(ReminderActionIds.taken), ReminderActionOutcome.rejected);
    expect(await eventTypes(), isEmpty);
  });
}
