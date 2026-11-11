import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/motion.dart';
import 'package:pillpal/src/theme/page_transitions.dart';
import 'package:pillpal/src/theme/reduced_motion.dart';

const _first = Key('first');
const _second = Key('second');

Widget _app({bool reduced = false}) {
  return MaterialApp(
    theme: buildPillPalTheme(brightness: Brightness.light, senior: false),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        key: _first,
        body: TextButton(
          key: const Key('open'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(key: _second),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
}

double _left(WidgetTester tester) => tester.getTopLeft(find.byKey(_second)).dx;

double _opacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(_second),
            matching: find.byType(FadeTransition),
          )
          .first,
    )
    .opacity
    .value;

double _width(WidgetTester tester) =>
    tester.view.physicalSize.width / tester.view.devicePixelRatio;

void main() {
  test('the tokens are the values of the design', () {
    expect(PillPalMotion.fast, const Duration(milliseconds: 150));
    expect(PillPalMotion.base, const Duration(milliseconds: 250));
    expect(PillPalMotion.slow, const Duration(milliseconds: 350));
    expect(PillPalMotion.standard, const Cubic(.2, 0, 0, 1));
    expect(
      PillPalMotion.emphasizedDecelerate,
      const Cubic(.05, .7, .1, 1),
    );
  });

  testWidgets('reduced() reads the system flag', (tester) async {
    late bool normal;
    late bool reduced;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Builder(
          builder: (context) {
            normal = PillPalMotion.reduced(context);
            return MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: Builder(
                builder: (context) {
                  reduced = PillPalMotion.reduced(context);
                  return const SizedBox();
                },
              ),
            );
          },
        ),
      ),
    );
    expect(normal, isFalse);
    expect(reduced, isTrue);
  });

  testWidgets('stateChange is instant only with reduced motion', (
    tester,
  ) async {
    late Duration normal;
    late Duration reduced;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Builder(
          builder: (context) {
            normal = PillPalMotion.stateChange(context);
            return MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: Builder(
                builder: (context) {
                  reduced = PillPalMotion.stateChange(context);
                  return const SizedBox();
                },
              ),
            );
          },
        ),
      ),
    );
    expect(normal, PillPalMotion.base);
    expect(reduced, Duration.zero);
  });

  group('screen transitions', () {
    testWidgets('forward: slides in from the right, opacity .6 to 1, base', (
      tester,
    ) async {
      await tester.pumpWidget(_app());
      final width = _width(tester);
      await tester.tap(find.byKey(const Key('open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));

      // The first frame: at the right edge and 60 % opaque.
      expect(_left(tester), greaterThan(width * 0.8));
      expect(
        _opacity(tester),
        closeTo(PillPalPageTransitionsBuilder.edgeOpacity, 0.1),
      );

      await tester.pump(PillPalMotion.base ~/ 4);
      expect(_left(tester), inExclusiveRange(0, width));
      expect(_opacity(tester), inExclusiveRange(0.6, 1));

      // The route takes `base`; the curve ends at rest, fully opaque.
      await tester.pump(PillPalMotion.base);
      expect(_left(tester), 0);
      expect(_opacity(tester), 1);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('back: the reverse, out to the right, down to .6', (
      tester,
    ) async {
      await tester.pumpWidget(_app());
      final width = _width(tester);
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop();
      await tester.pump();
      await tester.pump(PillPalMotion.base ~/ 4);
      expect(_left(tester), inExclusiveRange(0, width));
      expect(_opacity(tester), inExclusiveRange(0.6, 1));

      await tester.pumpAndSettle();
      expect(find.byKey(_second), findsNothing);
    });

    testWidgets('forward and back use different curves', (tester) async {
      await tester.pumpWidget(_app());
      await tester.tap(find.byKey(const Key('open')));
      await tester.pump();
      await tester.pump(PillPalMotion.base ~/ 4);
      final goingIn = _left(tester);
      await tester.pumpAndSettle();

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();
      await tester.pump(PillPalMotion.base ~/ 4);
      final goingOut = _left(tester);
      // A quarter of the way in has covered most of the distance (decelerate);
      // a quarter of the way out has covered less (standard).
      expect(goingIn, lessThan(goingOut));
    });

    testWidgets('reduced motion: the screen fades in place, in fast', (
      tester,
    ) async {
      await tester.pumpWidget(_app(reduced: true));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pump();
      await tester.pump(PillPalMotion.fast ~/ 3);

      expect(_left(tester), 0);
      expect(_opacity(tester), inExclusiveRange(0, 1));
      await tester.pump(PillPalMotion.fast);
      expect(_opacity(tester), 1);
    });

    testWidgets('the fade-only page does not slide', (tester) async {
      final animation = AnimationController(
        vsync: tester,
        duration: PillPalMotion.base,
        value: 0.5,
      );
      addTearDown(animation.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: PillPalFadePageTransition(
            animation: animation,
            child: const SizedBox.expand(key: _second),
          ),
        ),
      );
      expect(_left(tester), 0);
      expect(_opacity(tester), inExclusiveRange(0, 1));
    });
  });

  testWidgets('the theme gives every platform the same builder', (tester) async {
    final theme = buildPillPalTheme(brightness: Brightness.dark, senior: true);
    for (final platform in TargetPlatform.values) {
      expect(
        theme.pageTransitionsTheme.builders[platform],
        isA<PillPalPageTransitionsBuilder>(),
        reason: '$platform',
      );
    }
    expect(
      const PillPalPageTransitionsBuilder().transitionDuration,
      PillPalMotion.base,
    );
  });

  test('buttons ease their tint in base; reduced motion makes it instant', () {
    final theme = buildPillPalTheme(brightness: Brightness.light, senior: false);
    final styles = [
      theme.filledButtonTheme.style,
      theme.outlinedButtonTheme.style,
      theme.textButtonTheme.style,
      theme.elevatedButtonTheme.style,
    ];
    for (final style in styles) {
      expect(style?.animationDuration, PillPalMotion.base);
    }

    final instant = withInstantStateChanges(theme);
    final instantStyles = [
      instant.filledButtonTheme.style,
      instant.outlinedButtonTheme.style,
      instant.textButtonTheme.style,
      instant.elevatedButtonTheme.style,
    ];
    for (final style in instantStyles) {
      expect(style?.animationDuration, Duration.zero);
    }
    // The rest of the theme is untouched.
    expect(
      instant.filledButtonTheme.style?.minimumSize?.resolve({}),
      theme.filledButtonTheme.style?.minimumSize?.resolve({}),
    );
  });
}
