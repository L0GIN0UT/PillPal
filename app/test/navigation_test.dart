import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/app.dart';
import 'package:pillpal/src/features/medications/medications_screen.dart';
import 'package:pillpal/src/features/shell/home_shell.dart';
import 'package:pillpal/src/features/today/today_screen.dart';
import 'package:pillpal/src/theme/motion.dart';

import 'helpers.dart';

void main() {
  testWidgets('starts on Today with four tabs', (tester) async {
    await pumpApp(tester);

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(4));
    expect(
      find.text('No medications yet. Add the first one and PillPal will '
          'remind you on time.'),
      findsOneWidget,
    );
  });

  testWidgets('after loading the shell fades in, it never slides', (
    tester,
  ) async {
    useTallPhoneSurface(tester);
    final container = createContainer(TestHarness());
    await tester.pumpWidget(
      UncontrolledProviderScope(
          container: container, child: const PillPalApp()),
    );
    var seen = false;
    // Frame by frame through the redirect from the loading screen.
    for (var frame = 0; frame < 60; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final shell = find.byType(HomeShell);
      if (shell.evaluate().isNotEmpty) {
        seen = true;
        expect(tester.getRect(shell).left, 0, reason: 'frame $frame');
      }
    }
    expect(seen, isTrue);
    await tester.pumpAndSettle();
  });

  testWidgets('switches tabs', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.calendar_month_outlined));
    await tester.pumpAndSettle();
    expect(find.text('October 2026'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.people_outline).last);
    await tester.pumpAndSettle();
    // Nobody yet: the empty state with its actions (B2-EmptyFamily).
    expect(find.text('No one here yet'), findsOneWidget);
    expect(find.byKey(const Key('accept-invite')), findsOneWidget);
  });

  testWidgets('a tab switch turns the page and keeps the bar still', (
    tester,
  ) async {
    await pumpApp(tester);
    final bar = tester.getRect(find.byType(NavigationBar));
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;

    await tester.tap(find.byIcon(Icons.medication_outlined).last);
    await tester.pump();
    await tester.pump(PillPalMotion.slow ~/ 3);

    final today = tester.getRect(find.byType(TodayScreen));
    final medications = tester.getRect(find.byType(MedicationsScreen));
    expect(medications.left - today.left, closeTo(width, 0.001));
    expect(today.left, lessThan(0));
    expect(medications.left, greaterThan(0));
    expect(tester.getRect(find.byType(NavigationBar)), bar);

    await tester.pumpAndSettle();
    expect(find.byType(TodayScreen), findsNothing);
    expect(tester.getRect(find.byType(MedicationsScreen)).left, 0);
  });

  testWidgets('reduced motion: a tab switch fades and nothing moves', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.medication_outlined).last);
    await tester.pump();
    await tester.pump(PillPalMotion.fast ~/ 2);

    expect(tester.getRect(find.byType(TodayScreen)).left, 0);
    expect(tester.getRect(find.byType(MedicationsScreen)).left, 0);
    await tester.pump(PillPalMotion.fast);
    expect(find.byType(TodayScreen), findsNothing);
  });

  testWidgets('add medication button opens the new medication form',
      (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('Add medication'));
    await tester.pumpAndSettle();

    expect(find.text('New medication'), findsOneWidget);
  });

  testWidgets('medications tab shows the empty list', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('Medications'));
    await tester.pumpAndSettle();

    expect(find.text('Your medications will appear here.'), findsOneWidget);
  });

  testWidgets('settings opens from Today and goes back', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Large text and buttons'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
