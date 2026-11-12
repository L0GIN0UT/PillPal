import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/common/round_check_button.dart';
import 'package:pillpal/src/features/doses/dose_status.dart';
import 'package:pillpal/src/features/today/dose_tile.dart';

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

  testWidgets('a missed dose has a round check that takes it at once',
      (tester) async {
    final calls = <String>[];
    final screen = fixtureTodayScreen(TestHarness(), calls: calls);

    await _inOneCell(tester, screen, (tester) async {
      expect(
        tester.widget(find.byKey(ValueKey('dose-take-${_key('08:00')}'))),
        isA<RoundCheckButton>(),
      );
      // A taken dose has none.
      expect(find.byKey(ValueKey('dose-take-${_key('07:00')}')), findsNothing);
      // The hero comes first in the tree: a journey's first `dose-take-`
      // is the dose to take now.
      final takes = find
          .byWidgetPredicate((w) {
            final key = w.key;
            return key is ValueKey<String> &&
                key.value.startsWith('dose-take-');
          })
          .evaluate()
          .map((e) => (e.widget.key! as ValueKey<String>).value)
          .toList();
      expect(takes.first, 'dose-take-${_key('09:50')}');

      await tester.tap(find.byKey(ValueKey('dose-take-${_key('08:00')}')));
      await tester.pump();
      expect(calls, ['take 08:00']);
    });
  });

  testWidgets('a missed row still opens take and skip on tap', (tester) async {
    final calls = <String>[];
    final screen = fixtureTodayScreen(TestHarness(), calls: calls);

    await _inOneCell(tester, screen, (tester) async {
      await tester.tap(find.byKey(ValueKey('dose-missed-${_key('08:00')}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('dose-sheet-skip')));
      await tester.pumpAndSettle();

      expect(calls, ['skip 08:00']);
    });
  });

  testWidgets('a day with only a missed dose has no hero and no banner',
      (tester) async {
    final screen = fixtureTodayScreen(
      TestHarness(),
      state: fixtureState([fixtureDose('08:00', DoseStatus.missed)]),
    );

    await _inOneCell(tester, screen, (tester) async {
      expect(find.byKey(const Key('today-all-taken')), findsNothing);
      expect(find.byType(DoseTile), findsOneWidget);
      expect(
        tester.widget<DoseTile>(find.byType(DoseTile)).layout,
        DoseTileLayout.past,
      );
    });
  });

  testWidgets('the hero card tells screen readers it opens more actions',
      (tester) async {
    final screen = fixtureTodayScreen(TestHarness());
    final semantics = tester.ensureSemantics();

    await _inOneCell(tester, screen, (tester) async {
      final hint = find.descendant(
        of: find.byKey(ValueKey(_key('09:50'))),
        matching: find.bySemanticsLabel(RegExp('.*')),
      );
      expect(hint, findsWidgets);
      expect(
        find.semantics.byHint('Opens more actions, such as skip'),
        findsOneWidget,
      );
    });
    semantics.dispose();
  });
}
