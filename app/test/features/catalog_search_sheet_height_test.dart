import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/data/config.dart';

import 'catalog_ui_env.dart';

// The search sheet keeps one height while it is open: it fills the space
// above the keyboard (up to 90 % of the screen) whatever the body shows, so
// typing does not make it jump; the body (spinner, message, results) lives
// in the area below the field and the results scroll inside it.

const double _pixelRatio = 3;
const double _keyboard = 300;

final Finder _panel = find.byKey(const Key('catalog-search-panel'));
final Finder _field = find.byKey(const Key('catalog-search-text'));

Future<void> _useScreen(
  WidgetTester tester,
  Size size, {
  double keyboard = _keyboard,
}) async {
  tester.view
    ..devicePixelRatio = _pixelRatio
    ..physicalSize = size * _pixelRatio
    ..viewInsets = FakeViewPadding(bottom: keyboard * _pixelRatio);
  await tester.pump();
}

Future<void> _openSheet(WidgetTester tester, CatalogUiEnv env) async {
  await env.openNewForm(tester);
  await tester.ensureVisible(find.byKey(const Key('med-catalog')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('med-catalog')));
  await tester.pumpAndSettle();
}

/// Types [text] and lets the pause pass (the answer waits for the gate).
Future<void> _typeAndWait(WidgetTester tester, String text) async {
  await tester.enterText(_field, text);
  await tester.pump(CatalogPolicy.searchDebounce);
  await tester.pump();
}

List<Map<String, Object?>> _manyResults(int count) => [
      for (var i = 0; i < count; i++)
        searchResultJson(id: 'ru-$i', name: 'Synthetic Tablet $i'),
    ];

void main() {
  testWidgets('the sheet keeps one height in idle, loading and loaded',
      (tester) async {
    const screen = Size(360, 800);
    final env = CatalogUiEnv()..results = _manyResults(30);
    await env.pump(tester);
    await _useScreen(tester, screen);
    await _openSheet(tester, env);

    final idle = tester.getRect(_panel);
    // Fills the space above the keyboard (less than 90 % of the screen),
    // below the drag handle.
    expect(idle.bottom, screen.height - _keyboard);
    expect(idle.top, lessThan(kMinInteractiveDimension * 2));

    final gate = env.searchGate = Completer<void>();
    await _typeAndWait(tester, 'syn');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.getRect(_panel), idle, reason: 'spinner');

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalog-results')), findsOneWidget);
    expect(tester.getRect(_panel), idle, reason: 'results');

    final refine = env.searchGate = Completer<void>();
    await _typeAndWait(tester, 'synt');
    expect(find.byKey(const Key('catalog-loading-bar')), findsOneWidget);
    expect(tester.getRect(_panel), idle, reason: 'refining');
    refine.complete();
    await tester.pumpAndSettle();

    // The results scroll inside the area, which ends above the keyboard.
    final results = tester.getRect(find.byKey(const Key('catalog-results')));
    expect(results.bottom, lessThanOrEqualTo(idle.bottom));
    expect(find.byKey(const ValueKey('catalog-result-ru-29')), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('catalog-result-ru-29')),
      200,
      scrollable: find.descendant(
        of: find.byKey(const Key('catalog-results')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(tester.getRect(_panel), idle, reason: 'scrolled');
  });

  testWidgets('a short answer and a message keep the height too',
      (tester) async {
    const screen = Size(360, 800);
    final env = CatalogUiEnv()..results = _manyResults(1);
    await env.pump(tester);
    await _useScreen(tester, screen);
    await _openSheet(tester, env);
    final idle = tester.getRect(_panel);

    await tester.enterText(_field, 'syn');
    await tester.pump(CatalogPolicy.searchDebounce);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalog-results')), findsOneWidget);
    expect(tester.getRect(_panel), idle, reason: 'one result');

    env.results = [];
    await tester.enterText(_field, 'nothing');
    await tester.pump(CatalogPolicy.searchDebounce);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalog-empty')), findsOneWidget);
    expect(tester.getRect(_panel), idle, reason: 'empty');
  });

  testWidgets('without the keyboard the sheet takes 90 % of the screen',
      (tester) async {
    const screen = Size(360, 800);
    final env = CatalogUiEnv();
    await env.pump(tester);
    await _useScreen(tester, screen, keyboard: 0);
    await _openSheet(tester, env);

    expect(tester.getSize(_panel).height, screen.height * 0.9);
  });

  testWidgets('a Fold cover screen with the keyboard and large text fits',
      (tester) async {
    const screen = Size(280, 653);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final env = CatalogUiEnv()..results = _manyResults(10);
    await env.pump(tester, locale: const Locale('ru'));
    await _useScreen(tester, screen, keyboard: 260);
    await _openSheet(tester, env);
    final idle = tester.getRect(_panel);
    expect(idle.bottom, lessThanOrEqualTo(screen.height - 260));

    final gate = env.searchGate = Completer<void>();
    await _typeAndWait(tester, 'синт');
    expect(tester.getRect(_panel), idle, reason: 'spinner');
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalog-results')), findsOneWidget);
    expect(tester.getRect(_panel), idle, reason: 'results');
    // A layout overflow is reported as an exception.
    expect(tester.takeException(), isNull);
  });
}
