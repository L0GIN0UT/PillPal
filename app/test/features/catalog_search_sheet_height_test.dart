import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/features/catalog/catalog_search_sheet.dart';
import 'package:pillpal/src/features/common/dosage_form_avatar.dart';
import 'package:pillpal/src/features/common/sheet_scaffold.dart';
import 'package:pillpal/src/theme/app_theme.dart';

import '../data/catalog_fixtures.dart';
import 'catalog_ui_env.dart';

// The search sheet keeps one height while it is open: it fills the space
// above the keyboard (up to 90 % of the screen) whatever the body shows, so
// typing does not make it jump; the body (spinner, message, results) lives
// in the area below the field and the results scroll inside it. Widget
// tests draw every glyph 1 em wide, so the names below are sized for that.

const double _pixelRatio = 3;
const double _keyboard = 300;

final Finder _sheet = find.byType(SheetScaffold);
final Finder _area = find.byKey(const Key('catalog-search-area'));
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
  addTearDown(tester.view.reset);
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

/// Types [text] and settles on the answer.
Future<void> _search(WidgetTester tester, String text) async {
  await tester.enterText(_field, text);
  await tester.pump(CatalogPolicy.searchDebounce);
  await tester.pumpAndSettle();
}

List<Map<String, Object?>> _manyResults(int count) => [
      for (var i = 0; i < count; i++)
        searchResultJson(id: 'ru-$i', name: 'Synthetic Tablet $i'),
    ];

Finder _avatarOf(String id) => find.descendant(
      of: find.byKey(ValueKey('catalog-result-$id')),
      matching: find.byType(DosageFormAvatar),
    );

/// Both rects of the open sheet: the whole sheet and the body area.
(Rect, Rect) _rects(WidgetTester tester) =>
    (tester.getRect(_sheet), tester.getRect(_area));

void main() {
  testWidgets('the sheet keeps one height in idle, loading and loaded',
      (tester) async {
    const screen = Size(360, 800);
    final env = CatalogUiEnv()..results = _manyResults(30);
    await env.pump(tester);
    await _useScreen(tester, screen);
    await _openSheet(tester, env);

    final idle = _rects(tester);
    // The sheet reaches the screen bottom (the keyboard pads it) and its
    // body ends above the keyboard.
    expect(idle.$1.bottom, screen.height);
    expect(idle.$2.bottom, lessThanOrEqualTo(screen.height - _keyboard));

    final gate = env.searchGate = Completer<void>();
    await _typeAndWait(tester, 'syn');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(_rects(tester), idle, reason: 'spinner');

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalog-results')), findsOneWidget);
    expect(_rects(tester), idle, reason: 'results');

    final refine = env.searchGate = Completer<void>();
    await _typeAndWait(tester, 'synt');
    expect(find.byKey(const Key('catalog-loading-bar')), findsOneWidget);
    expect(_rects(tester), idle, reason: 'refining');
    refine.complete();
    await tester.pumpAndSettle();

    // The results scroll inside the area.
    final results = tester.getRect(find.byKey(const Key('catalog-results')));
    expect(results.bottom, lessThanOrEqualTo(idle.$2.bottom));
    expect(find.byKey(const ValueKey('catalog-result-ru-29')), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('catalog-result-ru-29')),
      200,
      scrollable: find.descendant(
        of: find.byKey(const Key('catalog-results')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(_rects(tester), idle, reason: 'scrolled');
  });

  testWidgets('a short answer and a message keep the height too',
      (tester) async {
    const screen = Size(360, 800);
    final env = CatalogUiEnv()..results = _manyResults(1);
    await env.pump(tester);
    await _useScreen(tester, screen);
    await _openSheet(tester, env);
    final idle = _rects(tester);

    await _search(tester, 'syn');
    expect(find.byKey(const Key('catalog-results')), findsOneWidget);
    expect(_rects(tester), idle, reason: 'one result');

    env.results = [];
    await _search(tester, 'nothing');
    expect(find.byKey(const Key('catalog-empty')), findsOneWidget);
    expect(_rects(tester), idle, reason: 'empty');
  });

  testWidgets('without the keyboard the sheet takes 90 % of the screen',
      (tester) async {
    const screen = Size(360, 800);
    final env = CatalogUiEnv();
    await env.pump(tester);
    await _useScreen(tester, screen, keyboard: 0);
    await _openSheet(tester, env);

    expect(
      tester.getSize(_sheet).height,
      screen.height * PillPalSizes.sheetMaxHeightFactor,
    );
  });

  testWidgets('a Fold cover with the keyboard and large text scrolls whole',
      (tester) async {
    const screen = Size(280, 653);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final env = CatalogUiEnv()
      ..results = [
        searchResultJson(id: productA, name: 'Синт'),
        ..._manyResults(9),
      ];
    await env.pump(tester, locale: const Locale('ru'));
    await _useScreen(tester, screen, keyboard: 260);
    await _openSheet(tester, env);
    final idle = _rects(tester);

    final gate = env.searchGate = Completer<void>();
    await _typeAndWait(tester, 'синт');
    expect(_rects(tester), idle, reason: 'spinner');
    gate.complete();
    await tester.pumpAndSettle();
    expect(_rects(tester), idle, reason: 'results');
    // A layout overflow is reported as an exception.
    expect(tester.takeException(), isNull);

    // Too short for the field and the results: the whole sheet scrolls,
    // and the first result can be reached and picked.
    final outer =
        find.descendant(of: _sheet, matching: find.byType(Scrollable)).first;
    expect(
      tester.state<ScrollableState>(outer).position.maxScrollExtent,
      greaterThan(0),
    );
    final first = find.byKey(const ValueKey('catalog-result-$productA'));
    await tester.scrollUntilVisible(first, 100, scrollable: outer);
    await tester.tap(first);
    await tester.pumpAndSettle();
    expect(find.byType(CatalogSearchSheet), findsNothing);
    expect(
      env.traffic.requests.map((request) => request.url.path),
      contains('/v1/products/get'),
    );
  });

  testWidgets('on a cover screen a result drops its tile, not its words',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final env = CatalogUiEnv()
      ..results = [searchResultJson(id: 'ru-1', name: 'Синтетин Тева')];
    await env.pump(tester, locale: const Locale('ru'));

    await _useScreen(tester, const Size(411, 914));
    await _openSheet(tester, env);
    await _search(tester, 'атор');
    expect(_avatarOf('ru-1'), findsOneWidget, reason: 'a phone keeps it');

    await _useScreen(tester, const Size(280, 653), keyboard: 240);
    await tester.pumpAndSettle();
    expect(_avatarOf('ru-1'), findsNothing, reason: 'the cover drops it');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the rows of the card drop their tiles together', (tester) async {
    final env = CatalogUiEnv()
      ..results = [
        searchResultJson(id: 'short', name: 'Синт'),
        searchResultJson(id: 'long', name: 'Синтетинсинтетинсинт'),
      ];
    await env.pump(tester);
    await _useScreen(tester, const Size(360, 800));
    await _openSheet(tester, env);
    await _search(tester, 'syn');

    // The long word does not fit beside the tile: neither row keeps one.
    expect(_avatarOf('long'), findsNothing);
    expect(_avatarOf('short'), findsNothing);

    env.results = [searchResultJson(id: 'short', name: 'Синт')];
    await _search(tester, 'synt');
    expect(_avatarOf('short'), findsOneWidget, reason: 'alone it fits');
  });
}
