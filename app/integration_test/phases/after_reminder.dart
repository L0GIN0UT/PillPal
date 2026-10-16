import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/routing/router.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../support/app_driver.dart';
import '../support/reminders.dart';

/// Phase `taken`: the reminder fired while the app was terminated and the
/// workflow tapped its **Taken** action, which ran in the plugin's
/// background isolate (ADR 0001 §7). On the next start: exactly one
/// `taken` event for the occurrence, nothing else recorded for it, no
/// notification of it left (tray or pending), Today shows it taken, and the
/// event syncs (the workflow then counts it in the backend database).
Future<void> takenPhase(WidgetTester tester) async {
  final container = await launchApp(tester);
  await waitFor(tester, find.byType(NavigationBar), reason: 'Today');
  final db = container.read(databaseProvider);

  final schedule = (await db.select(db.schedules).get()).single;
  final events = [
    for (final event in await db.select(db.doseEvents).get())
      if (event.occurrenceKey?.startsWith('${schedule.id}/') ?? false) event,
  ];
  expect(
    [for (final event in events) event.eventType],
    [DoseEventType.taken.wire],
    reason: 'one Taken tap records exactly one event',
  );
  final key = events.single.occurrenceKey!;

  await waitFor(
    tester,
    find.byKey(ValueKey('dose-taken-$key')),
    reason: 'Today to show the dose as taken',
  );
  expect(await pendingFor(key), isEmpty, reason: 'settled: nothing pending');
  expect(
    [
      for (final notification in await activeNotifications())
        if (occurrenceKeyOf(notification.payload) == key) notification.id,
    ],
    isEmpty,
    reason: 'the tray is cleared',
  );

  await _syncEverything(container, db);
}

/// Phase `rearm`: started after `am force-stop`, which drops the app's
/// alarms while the plugin's cache still lists them. The first re-plan of
/// the process schedules every future reminder again (ADR 0001 §3); the
/// workflow checks AlarmManager afterwards.
Future<void> rearmPhase(WidgetTester tester) async {
  final container = await launchApp(tester);
  await pumpUntil(
    tester,
    () => hasPlanned(container),
    reason: 'the first re-plan after the force stop',
  );
  expect(await allPending(), isNotEmpty);
}

/// Phase `sign_out`: signing out erases the account's data and cancels
/// every reminder, pending and in the tray (ADR 0002 §1); the workflow
/// checks that no alarm of the app is left.
Future<void> signOutPhase(WidgetTester tester) async {
  final container = await launchApp(tester);
  await waitFor(tester, find.byType(NavigationBar), reason: 'Today');
  await pumpUntil(
    tester,
    () => hasPlanned(container),
    reason: 'reminders to be planned before signing out',
  );
  expect(await allPending(), isNotEmpty);

  container.read(routerProvider).go(AppRoutes.settings);
  await tapVisible(tester, find.byKey(const Key('sign-out')));
  await tapVisible(tester, find.byKey(const Key('confirm-sign-out')));
  await waitFor(
    tester,
    find.byKey(const Key('welcome-register')),
    reason: 'the welcome screen after signing out',
  );

  await pumpUntil(
    tester,
    () async => (await allPending()).isEmpty,
    reason: 'no pending reminder after signing out',
  );
  expect(await activeNotifications(), isEmpty);
  final db = container.read(databaseProvider);
  expect(await db.select(db.medications).get(), isEmpty);
  expect(await db.select(db.doseEvents).get(), isEmpty);
}

Future<void> _syncEverything(
  ProviderContainer container,
  AppDatabase db,
) async {
  final report = await container.read(syncEngineProvider).sync();
  expect(report.ok, isTrue, reason: 'sync of the recorded event');
  expect(await db.select(db.outbox).get(), isEmpty);
}
