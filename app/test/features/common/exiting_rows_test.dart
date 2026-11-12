import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/common/exiting_rows.dart';
import 'package:pillpal/src/theme/motion.dart';

import 'motion_test_host.dart';

void main() {
  Widget list(ValueNotifier<List<String>> ids, {bool reduced = false}) {
    return motionApp(
      ValueListenableBuilder<List<String>>(
        valueListenable: ids,
        builder: (context, current, _) => ExitingRows(
          rows: [
            for (final id in current)
              SizedBox(key: ValueKey(id), height: 48, child: Text(id)),
          ],
          builder: (context, rows) => Column(children: rows),
        ),
      ),
      reduced: reduced,
    );
  }

  testWidgets('a removed row fades and collapses in base, then is gone', (
    tester,
  ) async {
    final ids = ValueNotifier<List<String>>(['a', 'b', 'c']);
    addTearDown(ids.dispose);
    await tester.pumpWidget(list(ids));
    final belowBefore = tester.getTopLeft(find.text('c')).dy;

    ids.value = ['a', 'c'];
    await tester.pump();
    await tester.pump(PillPalMotion.base ~/ 4);
    expect(find.text('b'), findsOneWidget, reason: 'still leaving');
    final belowMid = tester.getTopLeft(find.text('c')).dy;
    expect(belowMid, lessThan(belowBefore));
    expect(belowMid, greaterThan(belowBefore - 48));
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(of: find.text('b'), matching: find.byType(FadeTransition))
          .first,
    );
    expect(fade.opacity.value, inExclusiveRange(0, 1));

    await tester.pump(PillPalMotion.base);
    expect(find.text('b'), findsNothing);
    expect(tester.getTopLeft(find.text('c')).dy, belowBefore - 48);
    expect(find.text('a'), findsOneWidget);
  });

  testWidgets('a leaving row takes no taps', (tester) async {
    var taps = 0;
    final ids = ValueNotifier<List<String>>(['a', 'b']);
    addTearDown(ids.dispose);
    await tester.pumpWidget(
      motionApp(
        ValueListenableBuilder<List<String>>(
          valueListenable: ids,
          builder: (context, current, _) => ExitingRows(
            rows: [
              for (final id in current)
                GestureDetector(
                  key: ValueKey(id),
                  onTap: () => taps++,
                  child: SizedBox(height: 48, child: Text(id)),
                ),
            ],
            builder: (context, rows) => Column(children: rows),
          ),
        ),
      ),
    );
    ids.value = ['a'];
    await tester.pump();
    await tester.pump(PillPalMotion.base ~/ 10);
    await tester.tap(find.text('b'), warnIfMissed: false);
    expect(taps, 0);
    await tester.pumpAndSettle();
  });

  testWidgets('new rows appear at once and the others keep their state', (
    tester,
  ) async {
    final ids = ValueNotifier<List<String>>(['a']);
    addTearDown(ids.dispose);
    await tester.pumpWidget(list(ids));

    ids.value = ['a', 'b'];
    await tester.pump();
    expect(find.text('b'), findsOneWidget);
    expect(tester.getSize(find.text('b')).height, greaterThan(0));
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('a row that comes back while leaving stays', (tester) async {
    final ids = ValueNotifier<List<String>>(['a', 'b']);
    addTearDown(ids.dispose);
    await tester.pumpWidget(list(ids));

    ids.value = ['a'];
    await tester.pump();
    await tester.pump(PillPalMotion.base ~/ 4);
    ids.value = ['a', 'b'];
    await tester.pumpAndSettle();

    expect(find.text('b'), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('b'))).height, 48);
  });

  double opacityOf(WidgetTester tester, String id) => tester
      .widget<FadeTransition>(
        find
            .ancestor(
              of: find.text(id),
              matching: find.byType(FadeTransition),
            )
            .first,
      )
      .opacity
      .value;

  testWidgets('rows removed together leave one after another', (
    tester,
  ) async {
    final ids = ValueNotifier<List<String>>(['a', 'b', 'c', 'd']);
    addTearDown(ids.dispose);
    await tester.pumpWidget(list(ids));

    ids.value = ['d'];
    await tester.pump();
    await tester.pump(PillPalMotion.stagger ~/ 2);
    expect(opacityOf(tester, 'a'), lessThan(1));
    expect(opacityOf(tester, 'b'), 1, reason: 'waits one step');
    expect(opacityOf(tester, 'c'), 1, reason: 'waits two steps');

    await tester.pump(PillPalMotion.stagger);
    expect(opacityOf(tester, 'b'), lessThan(1));
    expect(opacityOf(tester, 'c'), 1);

    // Each row takes `base` from its own start.
    await tester.pump(PillPalMotion.base - PillPalMotion.stagger);
    expect(find.text('a'), findsNothing);
    expect(find.text('b'), findsOneWidget);
    await tester.pump(PillPalMotion.stagger * 2);
    expect(find.text('b'), findsNothing);
    expect(find.text('c'), findsNothing);
    expect(find.text('d'), findsOneWidget);
  });

  testWidgets('the builder gets no rows once the last one has left', (
    tester,
  ) async {
    final ids = ValueNotifier<List<String>>(['a']);
    addTearDown(ids.dispose);
    await tester.pumpWidget(
      motionApp(
        ValueListenableBuilder<List<String>>(
          valueListenable: ids,
          builder: (context, current, _) => ExitingRows(
            rows: [
              for (final id in current)
                SizedBox(key: ValueKey(id), height: 48, child: Text(id)),
            ],
            builder: (context, rows) =>
                rows.isEmpty ? const Text('empty') : Column(children: rows),
          ),
        ),
      ),
    );

    ids.value = [];
    await tester.pump();
    await tester.pump(PillPalMotion.base ~/ 2);
    expect(find.text('a'), findsOneWidget);
    expect(find.text('empty'), findsNothing);

    await tester.pump(PillPalMotion.base);
    expect(find.text('a'), findsNothing);
    expect(find.text('empty'), findsOneWidget);
  });

  testWidgets('reduced motion: the row is gone at once', (tester) async {
    final ids = ValueNotifier<List<String>>(['a', 'b']);
    addTearDown(ids.dispose);
    await tester.pumpWidget(list(ids, reduced: true));

    ids.value = ['a'];
    await tester.pump();
    expect(find.text('b'), findsNothing);
  });

  testWidgets('a leaving row is not read out and takes no focus', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final ids = ValueNotifier<List<String>>(['a', 'b']);
    addTearDown(ids.dispose);
    await tester.pumpWidget(
      motionApp(
        ValueListenableBuilder<List<String>>(
          valueListenable: ids,
          builder: (context, current, _) => ExitingRows(
            rows: [
              for (final id in current)
                TextButton(
                  key: ValueKey(id),
                  onPressed: () {},
                  child: Text(id),
                ),
            ],
            builder: (context, rows) => Column(children: rows),
          ),
        ),
      ),
    );
    ids.value = ['a'];
    await tester.pump();
    await tester.pump(PillPalMotion.base ~/ 10);

    expect(find.text('b'), findsOneWidget, reason: 'still leaving');
    expect(find.semantics.byLabel('b'), findsNothing);
    expect(find.semantics.byLabel('a'), findsOne);
    expect(Focus.of(tester.element(find.text('b'))).canRequestFocus, isFalse);
    await tester.pumpAndSettle();
    semantics.dispose();
  });

  testWidgets('a whole clear is over in slow, however long the list', (
    tester,
  ) async {
    final ids = ValueNotifier<List<String>>([
      for (var i = 0; i < 10; i++) 'row$i',
    ]);
    addTearDown(ids.dispose);
    await tester.pumpWidget(list(ids));

    ids.value = [];
    await tester.pump();
    await tester.pump(PillPalMotion.slow + const Duration(milliseconds: 1));
    expect(find.textContaining('row'), findsNothing);
  });

  group('separators', () {
    const line = Key('line');

    Widget divided(ValueNotifier<List<String>> ids) => motionApp(
          ValueListenableBuilder<List<String>>(
            valueListenable: ids,
            builder: (context, current, _) => ExitingRows(
              rows: [
                for (final id in current)
                  SizedBox(key: ValueKey(id), height: 48, child: Text(id)),
              ],
              separator: const SizedBox(key: line, height: 2),
              builder: (context, rows) => Column(children: rows),
            ),
          ),
        );

    /// Where the text of [id] starts.
    double top(WidgetTester tester, String id) =>
        tester.getTopLeft(find.text(id)).dy;

    testWidgets('one line between neighbours at rest', (tester) async {
      final ids = ValueNotifier<List<String>>(['a', 'b', 'c']);
      addTearDown(ids.dispose);
      await tester.pumpWidget(divided(ids));

      expect(find.byKey(line), findsNWidgets(2));
      expect(top(tester, 'b') - top(tester, 'a'), 50);
      expect(top(tester, 'c') - top(tester, 'b'), 50);
    });

    for (final (removed, kept) in [
      ('a', ['b', 'c']),
      ('b', ['a', 'c']),
      ('c', ['a', 'b']),
    ]) {
      testWidgets('removing $removed: the lines that stay never jump', (
        tester,
      ) async {
        final ids = ValueNotifier<List<String>>(['a', 'b', 'c']);
        addTearDown(ids.dispose);
        await tester.pumpWidget(divided(ids));

        ids.value = kept;
        await tester.pump();
        // The last frame of the collapse: the row and its line are flat.
        await tester.pump(PillPalMotion.base);
        final collapsed = top(tester, kept[1]) - top(tester, kept[0]);
        await tester.pumpAndSettle();
        expect(find.text(removed), findsNothing);
        expect(find.byKey(line), findsOneWidget);
        // Removing the flat row changes nothing on screen.
        expect(top(tester, kept[1]) - top(tester, kept[0]), 50);
        expect(collapsed, closeTo(50, 0.5));
      });
    }

    testWidgets('the leaving top row takes the line under it', (
      tester,
    ) async {
      final ids = ValueNotifier<List<String>>(['a', 'b']);
      addTearDown(ids.dispose);
      await tester.pumpWidget(divided(ids));
      final start = top(tester, 'a');

      ids.value = ['b'];
      await tester.pump();
      await tester.pump(PillPalMotion.base ~/ 2);
      // The line goes with the row, so `b` moves up by less than 50.
      expect(top(tester, 'b'), inExclusiveRange(start, start + 50));
      await tester.pumpAndSettle();
      // At rest `b` sits where `a` was: no line above the first row.
      expect(top(tester, 'b'), start);
      expect(find.byKey(line), findsNothing);
    });
  });
}
