import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/common/exiting_rows.dart';
import 'package:pillpal/src/features/common/pillpal_banner.dart';
import 'package:pillpal/src/features/common/sheet_scaffold.dart';
import 'package:pillpal/src/features/common/show_pillpal_dialog.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/motion.dart';

Widget _app(Widget home, {bool reduced = false}) {
  return MaterialApp(
    theme: buildPillPalTheme(brightness: Brightness.light, senior: false),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: child!,
    ),
    home: Scaffold(body: home),
  );
}

void main() {
  group('dialog', () {
    const content = Key('dialog-content');

    Widget opener() => Builder(
          builder: (context) => TextButton(
            key: const Key('open'),
            onPressed: () => showPillPalDialog<void>(
              context: context,
              builder: (_) => const Dialog(
                child: SizedBox(key: content, width: 200, height: 100),
              ),
            ),
            child: const Text('open'),
          ),
        );

    double scale(WidgetTester tester) => tester
        .widget<ScaleTransition>(
          find
              .ancestor(
                of: find.byKey(content),
                matching: find.byType(ScaleTransition),
              )
              .first,
        )
        .scale
        .value;

    double opacity(WidgetTester tester) => tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.byKey(content),
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value;

    testWidgets('fades in and grows from 0.96 in base, leaves in fast', (
      tester,
    ) async {
      await tester.pumpWidget(_app(opener()));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pump();
      await tester.pump(PillPalMotion.base ~/ 10);

      expect(scale(tester), inExclusiveRange(0.96, 1));
      expect(opacity(tester), inExclusiveRange(0, 1));

      // Not finished at `fast`: the way in takes `base`.
      await tester.pump(PillPalMotion.fast);
      expect(opacity(tester), lessThan(1));
      await tester.pump(PillPalMotion.base);
      expect(scale(tester), 1);
      expect(opacity(tester), 1);

      Navigator.of(tester.element(find.byKey(content))).pop();
      await tester.pump();
      await tester.pump(PillPalMotion.fast + const Duration(milliseconds: 1));
      expect(find.byKey(content), findsNothing);
    });

    testWidgets('reduced motion: fades only, no scale', (tester) async {
      await tester.pumpWidget(_app(opener(), reduced: true));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pump();
      await tester.pump(PillPalMotion.base ~/ 10);

      expect(
        find.ancestor(
          of: find.byKey(content),
          matching: find.byType(ScaleTransition),
        ),
        findsNothing,
      );
      expect(opacity(tester), inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
    });
  });

  group('bottom sheet', () {
    const content = Key('sheet-content');

    Widget opener() => Builder(
          builder: (context) => TextButton(
            key: const Key('open'),
            onPressed: () => showPillPalSheet<void>(
              context,
              (_) => const SheetScaffold(
                children: [SizedBox(key: content, height: 100)],
              ),
            ),
            child: const Text('open'),
          ),
        );

    testWidgets('slides up in slow and closes in base', (tester) async {
      await tester.pumpWidget(_app(opener()));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      final start = tester.getTopLeft(find.byKey(content)).dy;

      final route = ModalRoute.of(tester.element(find.byKey(content)))!;
      expect(route.transitionDuration, PillPalMotion.slow);
      expect(route.reverseTransitionDuration, PillPalMotion.base);

      await tester.pump(PillPalMotion.slow);
      expect(tester.getTopLeft(find.byKey(content)).dy, lessThan(start));

      // The way down takes `base`: still on screen 40 ms before it ends.
      Navigator.of(tester.element(find.byKey(content))).pop();
      await tester.pump();
      await tester.pump(PillPalMotion.base - const Duration(milliseconds: 40));
      expect(find.byKey(content), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byKey(content), findsNothing);
    });
  });

  group('banner', () {
    const banner = Key('banner');

    double opacity(WidgetTester tester) => tester
        .widget<Opacity>(
          find
              .descendant(
                of: find.byKey(banner),
                matching: find.byType(Opacity),
              )
              .first,
        )
        .opacity;

    /// How far down the banner is from its place (negative: above it).
    double shift(WidgetTester tester) => tester
        .widget<Transform>(
          find
              .descendant(
                of: find.byKey(banner),
                matching: find.byType(Transform),
              )
              .first,
        )
        .transform
        .getTranslation()
        .y;

    Widget shown() => const PillPalBanner(key: banner, body: 'Note');

    testWidgets('slides down 16 px and fades in, in base', (tester) async {
      await tester.pumpWidget(_app(shown()));
      expect(opacity(tester), 0);
      expect(shift(tester), -16);

      await tester.pump(PillPalMotion.base ~/ 5);
      expect(opacity(tester), inExclusiveRange(0, 1));
      expect(shift(tester), inExclusiveRange(-16, 0));

      await tester.pump(PillPalMotion.base);
      expect(opacity(tester), 1);
      expect(shift(tester), 0);
    });

    testWidgets('keeps its semantics and a tap target from the first frame', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(shown()));

      expect(find.bySemanticsLabel('Note'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('plays once: a rebuild does not replay it', (tester) async {
      final tick = ValueNotifier<int>(0);
      addTearDown(tick.dispose);
      await tester.pumpWidget(
        _app(
          ValueListenableBuilder<int>(
            valueListenable: tick,
            builder: (context, _, __) => shown(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      tick.value++;
      await tester.pump();
      expect(opacity(tester), 1);
    });

    testWidgets('reduced motion: fades in place, in fast', (tester) async {
      await tester.pumpWidget(_app(shown(), reduced: true));
      await tester.pump(PillPalMotion.fast ~/ 3);

      expect(opacity(tester), inExclusiveRange(0, 1));
      expect(shift(tester), 0);
      await tester.pump(PillPalMotion.fast);
      expect(opacity(tester), 1);
    });
  });

  group('rows that leave', () {
    Widget list(ValueNotifier<List<String>> ids, {bool reduced = false}) {
      return _app(
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
        _app(
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

    testWidgets('reduced motion: the row is gone at once', (tester) async {
      final ids = ValueNotifier<List<String>>(['a', 'b']);
      addTearDown(ids.dispose);
      await tester.pumpWidget(list(ids, reduced: true));

      ids.value = ['a'];
      await tester.pump();
      expect(find.text('b'), findsNothing);
    });
  });
}
