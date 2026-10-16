import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/reminders/providers.dart';
import 'package:pillpal/src/reminders/reminder_content.dart';
import 'package:pillpal/src/routing/router.dart';

import '../support/app_driver.dart';
import '../support/host.dart';
import '../support/reminders.dart';

/// How far ahead the journey's dose is scheduled: long enough for the rest
/// of this phase, short enough for the workflow to wait for it.
const int _minutesAhead = 3;

/// Phase `onboarding` (fresh install, permissions granted by the workflow):
/// register, verify with the code from the backend log, add a medication
/// with a daily dose a few minutes ahead, see it on Today, and check the
/// scheduled reminder in the plugin - its text with and without "hide
/// medication names". The app is then terminated by the workflow and the
/// reminder must fire.
Future<void> onboardingPhase(WidgetTester tester, HostControl host) async {
  await _avoidMidnight();
  final container = await launchApp(tester);
  await _register(tester, host);
  final db = container.read(databaseProvider);
  await pumpUntil(
    tester,
    () async => (await db.select(db.profiles).get()).isNotEmpty,
    reason: 'the self profile to arrive by sync',
  );

  final time = _timeAhead(DateTime.now());
  await _addMedication(tester, time);
  final key = await _todayShowsDose(tester, container, time);
  await _checkReminder(tester, container, key);

  final report = await container.read(syncEngineProvider).sync();
  expect(report.ok, isTrue, reason: 'sync after onboarding');
}

Future<void> _register(WidgetTester tester, HostControl host) async {
  await tapVisible(tester, find.byKey(const Key('welcome-register')));
  final email = 'emulator-${DateTime.now().microsecondsSinceEpoch}'
      '@example.com';
  await enterField(tester, const Key('auth-email'), email);
  await enterField(tester, const Key('auth-password'), 'emulator-password-1');
  final codesBefore = await host.codeCount();
  await tapVisible(tester, find.byKey(const Key('auth-submit')));
  await waitFor(tester, find.byKey(const Key('auth-code')));
  final code = await host.codeAfter(codesBefore);
  await enterField(tester, const Key('auth-code'), code);
  await tapVisible(tester, find.byKey(const Key('auth-submit')));
  await waitFor(tester, find.byType(NavigationBar), reason: 'Today');
}

Future<void> _addMedication(WidgetTester tester, String time) async {
  await tapVisible(tester, find.byKey(const Key('today-add')));
  await enterField(tester, const Key('med-name'), journeyMedicationName);
  await tapVisible(tester, find.byKey(const Key('med-save')));
  // The schedule editor opens with one daily dose at 08:00, from today.
  final slot = find.byKey(const ValueKey('slot-time-08:00'));
  await waitFor(tester, slot, reason: 'the schedule editor');
  await pumpFor(tester, const Duration(milliseconds: 600));
  await pickTime(tester, slot, time);
  await waitFor(tester, find.byKey(ValueKey('slot-time-$time')));
  await tapVisible(tester, find.byKey(const Key('schedule-save')));
  await pumpUntil(
    tester,
    () => find.byKey(const Key('schedule-save')).evaluate().isEmpty,
    reason: 'the schedule editor to close',
  );
}

/// Opens Today and returns the occurrence key of the journey's dose.
Future<String> _todayShowsDose(
  WidgetTester tester,
  ProviderContainer container,
  String time,
) async {
  final db = container.read(databaseProvider);
  await pumpUntil(
    tester,
    () async => (await db.select(db.schedules).get()).isNotEmpty,
    reason: 'the schedule to be saved',
  );
  final schedule = (await db.select(db.schedules).get()).single;
  container.read(routerProvider).go(AppRoutes.today);
  const prefix = 'dose-take-';
  final tile = find.byWidgetPredicate((widget) {
    final key = widget.key;
    return key is ValueKey<String> &&
        key.value.startsWith('$prefix${schedule.id}/') &&
        key.value.endsWith('T$time');
  });
  await waitFor(tester, tile, reason: 'Today to show the pending dose');
  expect(find.text(journeyMedicationName), findsWidgets);
  return (tester.widget(tile.first).key! as ValueKey<String>)
      .value
      .substring(prefix.length);
}

/// The reminder is scheduled exactly, with the medication's name, and
/// with the generic text while names are hidden.
Future<void> _checkReminder(
  WidgetTester tester,
  ProviderContainer container,
  String key,
) async {
  await pumpUntil(
    tester,
    () async => (await pendingFor(key)).isNotEmpty,
    reason: 'the reminder to be scheduled',
  );
  final status = reminderStatus(container);
  expect(status.permissions.notificationsEnabled, isTrue);
  expect(status.permissions.exactAlarmsAllowed, isTrue);
  expect(status.exactAlarms, isTrue);

  final strings = reminderStrings(container.read(reminderLocaleProvider));
  final shared = strings.reminderTitleShared(journeyMedicationName);
  expect((await pendingFor(key)).single.title, shared);

  final settings = container.read(reminderSettingsRepositoryProvider);
  await settings.setHideMedicationNames(hide: true);
  await _waitForTitle(tester, key, strings.reminderTitleGeneric);
  expect((await pendingFor(key)).single.body, strings.reminderBodyGeneric);

  await settings.setHideMedicationNames(hide: false);
  await _waitForTitle(tester, key, shared);
}

Future<void> _waitForTitle(WidgetTester tester, String key, String title) =>
    pumpUntil(
      tester,
      () async {
        final pending = await pendingFor(key);
        return pending.length == 1 && pending.single.title == title;
      },
      reason: 'the pending reminder to read "$title"',
    );

/// `HH:MM` of the next whole minute at least [_minutesAhead] - 1 minutes
/// after [now], on the same day (see [_avoidMidnight]).
String _timeAhead(DateTime now) {
  final at = DateTime(
    now.year,
    now.month,
    now.day,
    now.hour,
    now.minute + _minutesAhead,
  );
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(at.hour)}:${two(at.minute)}';
}

/// The dose must fall on the day the schedule starts and Today shows:
/// close to midnight, wait for the next day.
Future<void> _avoidMidnight() async {
  final now = DateTime.now();
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  final left = tomorrow.difference(now);
  if (left < const Duration(minutes: 10)) {
    await Future<void>.delayed(left + const Duration(seconds: 5));
  }
}
