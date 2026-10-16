import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/main.dart' as app;
import 'package:pillpal/src/app.dart';

// UI helpers for journeys on a real device: real time, real plugins, the
// real app entry point. Waits poll a condition with a deadline instead of
// `pumpAndSettle`, which never returns while a progress indicator spins.

/// Default wait for a screen or a background effect.
const Duration defaultWait = Duration(seconds: 30);

const Duration _pollStep = Duration(milliseconds: 200);
const double _scrollStep = 250;
const Duration _appearWait = Duration(seconds: 3);

/// Starts the app exactly as `main.dart` does and returns its providers.
Future<ProviderContainer> launchApp(WidgetTester tester) async {
  app.main();
  await pumpUntil(
    tester,
    () => find.byType(PillPalApp).evaluate().isNotEmpty,
    reason: 'the app to start',
  );
  return ProviderScope.containerOf(tester.element(find.byType(PillPalApp)));
}

/// Pumps frames until [condition] holds; fails after [timeout].
Future<void> pumpUntil(
  WidgetTester tester,
  FutureOr<bool> Function() condition, {
  required String reason,
  Duration timeout = defaultWait,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out after ${timeout.inSeconds} s waiting for $reason');
    }
    await tester.pump();
    await Future<void>.delayed(_pollStep);
  }
  await tester.pump();
}

/// Waits until [finder] finds something on screen.
Future<void> waitFor(
  WidgetTester tester,
  Finder finder, {
  String? reason,
  Duration timeout = defaultWait,
}) =>
    pumpUntil(
      tester,
      () => finder.evaluate().isNotEmpty,
      reason: reason ?? finder.describeMatch(Plurality.one),
      timeout: timeout,
    );

/// Pumps frames for [duration] (route transitions, dialogs).
Future<void> pumpFor(WidgetTester tester, Duration duration) async {
  final end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await tester.pump();
    await Future<void>.delayed(_pollStep);
  }
}

/// Taps [finder] once it is built, scrolling the screen's list to it first
/// if it does not become visible within a few seconds.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  if (!await _appears(tester, finder.hitTestable(), _appearWait)) {
    if (finder.evaluate().isNotEmpty) {
      // Built (list cache extent) but off screen or under the bottom bar.
      await tester.ensureVisible(finder.first);
    } else if (_mainScrollable().evaluate().isNotEmpty) {
      await tester.scrollUntilVisible(
        finder,
        _scrollStep,
        scrollable: _mainScrollable(),
      );
    }
    // Otherwise the screen is still loading.
    await waitFor(tester, finder.hitTestable());
  }
  await tester.tap(finder.hitTestable().first);
  await tester.pump();
}

Future<bool> _appears(
  WidgetTester tester,
  Finder finder,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      return false;
    }
    await tester.pump();
    await Future<void>.delayed(_pollStep);
  }
  return true;
}

/// Types [text] into the field [key].
Future<void> enterField(WidgetTester tester, Key key, String text) async {
  final field = find.byKey(key);
  await waitFor(tester, field);
  await tester.enterText(field, text);
  await tester.pump();
}

/// Picks [time] (`HH:MM`) in the Material time picker opened by [opener],
/// through its text input mode.
Future<void> pickTime(WidgetTester tester, Finder opener, String time) async {
  await tapVisible(tester, opener);
  final dialog = find.byType(TimePickerDialog);
  await waitFor(tester, dialog, reason: 'the time picker');
  final strings = MaterialLocalizations.of(tester.element(dialog));
  await tester.tap(find.byTooltip(strings.inputTimeModeButtonLabel));
  await pumpFor(tester, const Duration(milliseconds: 600));
  final fields = find.descendant(of: dialog, matching: find.byType(TextField));
  expect(fields, findsNWidgets(2), reason: 'hour and minute fields');
  await tester.enterText(fields.at(0), time.substring(0, 2));
  await tester.pump();
  await tester.enterText(fields.at(1), time.substring(3));
  await tester.pump();
  await tester.tap(find.descendant(
    of: dialog,
    matching: find.text(strings.okButtonLabel),
  ));
  await pumpUntil(
    tester,
    () => dialog.evaluate().isEmpty,
    reason: 'the time picker to close',
  );
}

/// The vertical list of the current screen: the first downward scrollable
/// in tree order, i.e. the outermost one.
Finder _mainScrollable() => find
    .byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    )
    .first;
