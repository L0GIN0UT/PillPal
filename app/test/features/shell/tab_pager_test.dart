import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/shell/tab_pager.dart';
import 'package:pillpal/src/theme/motion.dart';

const _width = 400.0;
const _height = 700.0;
const _barHeight = 56.0;
const _navKey = Key('nav');

/// A tab page that remembers a tap count and a scroll position.
class _Page extends StatefulWidget {
  const _Page(this.index);

  final int index;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  int taps = 0;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('page-${widget.index}'),
      color: Colors.white,
      child: Column(
        children: [
          TextButton(
            key: Key('tap-${widget.index}'),
            onPressed: () => setState(() => taps++),
            child: Text('page ${widget.index}: $taps'),
          ),
          Expanded(
            child: ListView(
              key: PageStorageKey<String>('list-${widget.index}'),
              children: [
                for (var i = 0; i < 60; i++)
                  SizedBox(height: 50, child: Text('$i')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The pager above a fixed bar; [index] picks the tab.
class _Host extends StatelessWidget {
  const _Host({required this.index});

  final ValueNotifier<int> index;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: ValueListenableBuilder<int>(
        valueListenable: index,
        builder: (context, current, _) => Scaffold(
          body: TabPager(
            currentIndex: current,
            children: const [_Page(0), _Page(1), _Page(2), _Page(3)],
          ),
          bottomNavigationBar: const SizedBox(key: _navKey, height: _barHeight),
        ),
      ),
    );
  }
}

Finder _tap(int i) => find.byKey(Key('tap-$i'));

Finder _page(int i) => find.byKey(Key('page-$i'));

double _left(WidgetTester tester, int i) => tester.getRect(_page(i)).left;

/// Whether page [i] may tick: every TickerMode above it is on.
bool _ticking(WidgetTester tester, int i) => tester
    .widgetList<TickerMode>(
      find.ancestor(
        of: find.byKey(Key('page-$i'), skipOffstage: false),
        matching: find.byType(TickerMode, skipOffstage: false),
      ),
    )
    .every((mode) => mode.enabled);

/// The focus node of the tap button of page [i].
FocusNode _focusOf(WidgetTester tester, int i) => Focus.of(
      tester.element(
        find.descendant(of: _tap(i), matching: find.byType(Text)),
      ),
    );

double _opacityOf(WidgetTester tester, int i) => tester
    .widget<Opacity>(
      find.ancestor(of: _page(i), matching: find.byType(Opacity)).first,
    )
    .opacity;

Future<ValueNotifier<int>> _pump(
  WidgetTester tester, {
  bool reduced = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(_width, _height);
  addTearDown(tester.view.reset);
  if (reduced) {
    // The system flag, as on a device: it also reaches the controllers.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }
  final index = ValueNotifier<int>(0);
  addTearDown(index.dispose);
  await tester.pumpWidget(_Host(index: index));
  return index;
}

Future<void> _select(
  WidgetTester tester,
  ValueNotifier<int> index,
  int to,
) async {
  index.value = to;
  await tester.pump();
}

void main() {
  testWidgets('at rest only the selected page is shown', (tester) async {
    await _pump(tester);

    expect(_tap(0), findsOneWidget);
    expect(_tap(1), findsNothing);
    expect(_left(tester, 0), 0);
  });

  testWidgets('the pages move together, old to the left, new from the right', (
    tester,
  ) async {
    final index = await _pump(tester);

    await _select(tester, index, 1);
    // The first frame of the turn: the new page waits at the right edge.
    expect(_left(tester, 1), closeTo(_width, 0.001));
    expect(_left(tester, 0), closeTo(0, 0.001));

    for (var step = 0; step < 3; step++) {
      await tester.pump(PillPalMotion.slow ~/ 4);
      final leaving = _left(tester, 0);
      final entering = _left(tester, 1);
      expect(_tap(0), findsOneWidget, reason: 'the old page is still there');
      expect(_tap(1), findsOneWidget, reason: 'the new page has come');
      expect(leaving, lessThan(0));
      expect(entering, greaterThan(0));
      // A full width apart, so each moved the same distance: no parallax.
      expect(entering - leaving, closeTo(_width, 0.001));
    }

    await tester.pump(PillPalMotion.slow);
    expect(_left(tester, 1), 0);
    expect(_tap(0), findsNothing);
  });

  testWidgets('a tab to the left enters from the left', (tester) async {
    final index = await _pump(tester);
    await _select(tester, index, 2);
    await tester.pumpAndSettle();

    await _select(tester, index, 1);
    expect(_left(tester, 1), closeTo(-_width, 0.001));
    await tester.pump(PillPalMotion.slow ~/ 4);
    expect(_left(tester, 1), lessThan(0));
    expect(_left(tester, 2), greaterThan(0));
    expect(_left(tester, 2) - _left(tester, 1), closeTo(_width, 0.001));
    await tester.pumpAndSettle();
    expect(_left(tester, 1), 0);
  });

  testWidgets('both pages stay opaque and full size: no fade, no scale', (
    tester,
  ) async {
    final index = await _pump(tester);
    await _select(tester, index, 1);
    await tester.pump(PillPalMotion.slow ~/ 3);

    for (final i in [0, 1]) {
      expect(
          tester.getSize(_page(i)), const Size(_width, _height - _barHeight));
      expect(_opacityOf(tester, i), 1);
    }
    final pager = find.byType(TabPager);
    for (final type in [FadeTransition, ScaleTransition, AnimatedScale]) {
      expect(
        find.descendant(
          of: pager,
          matching: find.byWidgetPredicate((w) => w.runtimeType == type),
        ),
        findsNothing,
        reason: '$type',
      );
    }
  });

  testWidgets('the bar under the pager does not move', (tester) async {
    final index = await _pump(tester);
    final rest = tester.getRect(find.byKey(_navKey));

    await _select(tester, index, 3);
    for (var step = 0; step < 4; step++) {
      await tester.pump(PillPalMotion.slow ~/ 4);
      expect(tester.getRect(find.byKey(_navKey)), rest);
    }
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(_navKey)), rest);
  });

  testWidgets('a tab keeps its state and scroll position', (tester) async {
    final index = await _pump(tester);
    await tester.tap(_tap(0));
    await tester.tap(_tap(0));
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();
    double pixels() =>
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;
    final scrolled = pixels();
    expect(scrolled, greaterThan(0));

    await _select(tester, index, 1);
    await tester.pumpAndSettle();
    await tester.tap(_tap(1));
    await _select(tester, index, 0);
    await tester.pumpAndSettle();

    expect(find.text('page 0: 2'), findsOneWidget);
    expect(pixels(), scrolled);
    await _select(tester, index, 1);
    await tester.pumpAndSettle();
    expect(find.text('page 1: 1'), findsOneWidget);
  });

  testWidgets('the leaving page takes no taps, the entering one does', (
    tester,
  ) async {
    final index = await _pump(tester);
    await _select(tester, index, 1);
    await tester.pump(PillPalMotion.slow ~/ 4);

    await tester.tap(_tap(0), warnIfMissed: false);
    await tester.tap(_tap(1));
    await tester.pumpAndSettle();
    expect(find.text('page 1: 1'), findsOneWidget);
    await _select(tester, index, 0);
    await tester.pumpAndSettle();
    expect(find.text('page 0: 0'), findsOneWidget);
  });

  testWidgets('mid-turn the leaving page is not read out nor focusable', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final index = await _pump(tester);
    await _select(tester, index, 1);
    await tester.pump(PillPalMotion.slow ~/ 4);

    expect(_tap(0), findsOneWidget, reason: 'still on screen');
    expect(find.semantics.byLabel('page 0: 0'), findsNothing);
    expect(find.semantics.byLabel('page 1: 0'), findsOne);
    expect(_focusOf(tester, 0).canRequestFocus, isFalse);
    expect(_focusOf(tester, 1).canRequestFocus, isTrue);
    await tester.pumpAndSettle();
    semantics.dispose();
  });

  testWidgets('a hidden tab ticks only while it turns', (tester) async {
    final index = await _pump(tester);
    expect(_ticking(tester, 0), isTrue);
    expect(_ticking(tester, 1), isFalse);

    await _select(tester, index, 1);
    await tester.pump(PillPalMotion.slow ~/ 4);
    expect(_ticking(tester, 0), isTrue);
    expect(_ticking(tester, 1), isTrue);
    expect(_ticking(tester, 2), isFalse);

    await tester.pumpAndSettle();
    expect(_ticking(tester, 0), isFalse);
    expect(_ticking(tester, 1), isTrue);
  });

  testWidgets('going back mid-turn plays it backwards, without a jump', (
    tester,
  ) async {
    final index = await _pump(tester);
    await _select(tester, index, 1);
    await tester.pump(PillPalMotion.slow ~/ 4);
    final before = _left(tester, 1);

    await _select(tester, index, 0);
    // The frame of the change keeps the place, the next one moves on.
    expect(_left(tester, 1), closeTo(before, 0.001));
    await tester.pump(const Duration(milliseconds: 1));
    final after = _left(tester, 1);
    expect(after, closeTo(before, _width * 0.1));
    // It goes back the way it came: to the right again.
    expect(after, greaterThan(before));
    expect(_left(tester, 0) + _width, closeTo(after, 0.001));

    await tester.pumpAndSettle();
    expect(_left(tester, 0), 0);
    expect(_tap(1), findsNothing);
  });

  testWidgets('a third tab mid-turn starts from where the page is', (
    tester,
  ) async {
    final index = await _pump(tester);
    await _select(tester, index, 1);
    await tester.pump(PillPalMotion.slow ~/ 4);
    final before = _left(tester, 1);

    await _select(tester, index, 3);
    // The frame of the change keeps the place, the next one moves on.
    expect(_left(tester, 1), closeTo(before, 0.001));
    await tester.pump(const Duration(milliseconds: 1));
    final after = _left(tester, 1);
    expect(after, closeTo(before, _width * 0.1));
    // The new page is glued to it, one width to the right.
    expect(_left(tester, 3) - after, closeTo(_width, 0.001));

    await tester.pumpAndSettle();
    expect(_left(tester, 3), 0);
    expect(_tap(1), findsNothing);
  });

  testWidgets('switching again mid-turn lands on the last tab', (tester) async {
    final index = await _pump(tester);
    await _select(tester, index, 1);
    await tester.pump(PillPalMotion.slow ~/ 4);
    await _select(tester, index, 3);
    await tester.pumpAndSettle();

    expect(_tap(3), findsOneWidget);
    expect(_tap(1), findsNothing);
    expect(_left(tester, 3), 0);
  });

  testWidgets('reduced motion: the pages fade in place, in fast', (
    tester,
  ) async {
    final index = await _pump(tester, reduced: true);

    await _select(tester, index, 1);
    await tester.pump(PillPalMotion.fast ~/ 2);
    expect(_left(tester, 0), 0);
    expect(_left(tester, 1), 0);
    expect(_tap(0), findsOneWidget);
    expect(_tap(1), findsOneWidget);
    expect(_opacityOf(tester, 0), inExclusiveRange(0, 1));
    expect(_opacityOf(tester, 1), inExclusiveRange(0, 1));

    // `fast` is the whole turn: with `slow` the old page would still be here.
    await tester.pump(PillPalMotion.fast);
    expect(_tap(0), findsNothing);
    expect(_opacityOf(tester, 1), 1);
  });
}
