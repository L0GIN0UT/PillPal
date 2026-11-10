import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';
import '../support/today_fixtures.dart';
import '../support/ui_matrix.dart';

// What the «Сейчас» card, the round check and the rows of «Уже было» do
// (docs/redesign-plan.md, R3a). Looks are covered by the matrix test.

String _key(String time) => fixtureKey(time);

/// One normal cell is enough: the behaviour does not depend on the theme.
Future<void> _inOneCell(
  WidgetTester tester,
  Widget screen,
  Future<void> Function(WidgetTester tester) body,
) async {
  var ran = false;
  await pumpUiMatrix(
    tester,
    (context) => screen,
    scales: const [1.0],
    sizes: const [Size(360, 800)],
    check: (tester, cell) async {
      if (cell.senior ||
          cell.brightness != Brightness.light ||
          cell.locale.languageCode != 'en') {
        return;
      }
      tester.view.physicalSize = const Size(360, 3000);
      await tester.pump();
      ran = true;
      await body(tester);
    },
  );
  expect(ran, isTrue);
}

void main() {
  testWidgets('«Принял» takes the dose of the hero', (tester) async {
    final calls = <String>[];
    final screen = fixtureTodayScreen(TestHarness(), calls: calls);

    await _inOneCell(tester, screen, (tester) async {
      await tester.tap(find.byKey(ValueKey('dose-take-${_key('09:50')}')));
      await tester.pump();

      expect(calls, ['take 09:50']);
    });
  });

  testWidgets('the snooze button snoozes the dose and says so', (tester) async {
    final calls = <String>[];
    final screen = fixtureTodayScreen(TestHarness(), calls: calls);

    await _inOneCell(tester, screen, (tester) async {
      await tester.tap(find.byKey(ValueKey('dose-snooze-${_key('09:50')}')));
      await tester.pump();

      expect(calls, ['snooze 09:50']);
      expect(find.text('Postponed'), findsOneWidget);
    });
  });

  testWidgets('the round check takes a later dose at once', (tester) async {
    final calls = <String>[];
    final screen = fixtureTodayScreen(TestHarness(), calls: calls);

    await _inOneCell(tester, screen, (tester) async {
      await tester.tap(find.byKey(ValueKey('dose-take-${_key('20:00')}')));
      await tester.pump();

      expect(calls, ['take 20:00']);
    });
  });

  testWidgets('a tap on the name of the hero offers take and skip',
      (tester) async {
    final calls = <String>[];
    final screen = fixtureTodayScreen(TestHarness(), calls: calls);

    await _inOneCell(tester, screen, (tester) async {
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey(_key('09:50'))),
          matching: find.text('Med 09:50 500 mg'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dose-sheet-skip')), findsOneWidget);

      await tester.tap(find.byKey(const Key('dose-sheet-skip')));
      await tester.pumpAndSettle();
      expect(calls, ['skip 09:50']);
    });
  });

  testWidgets('a missed dose is among the earlier ones and can still be taken',
      (tester) async {
    final calls = <String>[];
    final screen = fixtureTodayScreen(TestHarness(), calls: calls);

    await _inOneCell(tester, screen, (tester) async {
      await tester.tap(find.byKey(ValueKey('dose-missed-${_key('08:00')}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('dose-sheet-take')));
      await tester.pumpAndSettle();

      expect(calls, ['take 08:00']);
    });
  });
}
