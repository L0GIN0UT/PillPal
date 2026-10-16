import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

  testWidgets('switches tabs', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.calendar_month_outlined));
    await tester.pumpAndSettle();
    expect(
      find.text('Intake history will appear after the first dose.'),
      findsOneWidget,
    );

    await tester.tap(find.byIcon(Icons.people_outline).last);
    await tester.pumpAndSettle();
    expect(find.textContaining('without calling'), findsOneWidget);
  });

  testWidgets('add medication button opens the medications tab',
      (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('Add medication'));
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
