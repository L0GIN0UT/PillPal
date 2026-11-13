import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/data/config.dart';

import 'catalog_ui_env.dart';

// Search while typing (ADR 0015 §3): the sheet searches once the person
// stops typing for the debounce pause, never for a text shorter than the
// catalog accepts; the search button still searches at once.

const Duration _justBefore = Duration(milliseconds: 1);

final Finder _field = find.byKey(const Key('catalog-search-text'));
final Finder _go = find.byKey(const Key('catalog-search-go'));

/// The search texts the catalog received, in order.
List<String> _queries(CatalogUiEnv env) => [
      for (final request in env.traffic.requests)
        (jsonDecode(request.body) as Map<String, Object?>)['q']! as String,
    ];

Future<void> _openSheet(WidgetTester tester, CatalogUiEnv env) async {
  await env.openNewForm(tester);
  await tester.tap(find.byKey(const Key('med-catalog')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('typing searches once after a pause; short text sends nothing',
      (tester) async {
    final env = CatalogUiEnv();
    await env.pump(tester);
    await _openSheet(tester, env);

    await tester.enterText(_field, 's');
    await tester.pump(CatalogPolicy.searchDebounce * 2);
    expect(env.traffic.requests, isEmpty);
    expect(find.byKey(const Key('catalog-too-short')), findsNothing);

    await tester.enterText(_field, 'sy');
    await tester.pump(CatalogPolicy.searchDebounce - _justBefore);
    await tester.enterText(_field, 'syn');
    await tester.pump(CatalogPolicy.searchDebounce - _justBefore);
    expect(env.traffic.requests, isEmpty, reason: 'each key restarts it');
    await tester.pump(_justBefore);
    await tester.pumpAndSettle();

    expect(_queries(env), ['syn']);
    expect(find.byKey(const Key('catalog-empty')), findsOneWidget);
    await tester.pump(CatalogPolicy.searchDebounce * 2);
    expect(_queries(env), ['syn'], reason: 'the pause fires once');
  });

  testWidgets('the search button searches at once and ends the pause',
      (tester) async {
    final env = CatalogUiEnv();
    await env.pump(tester);
    await _openSheet(tester, env);

    await tester.enterText(_field, 'syn');
    await tester.tap(_go);
    await tester.pumpAndSettle();
    expect(_queries(env), ['syn']);

    await tester.pump(CatalogPolicy.searchDebounce * 2);
    await tester.pumpAndSettle();
    expect(_queries(env), ['syn']);
  });

  testWidgets('the results stay on screen while typing refines them',
      (tester) async {
    final env = CatalogUiEnv()..results = [searchResultJson(id: 'ru-1')];
    await env.pump(tester);
    await _openSheet(tester, env);
    await tester.enterText(_field, 'syn');
    await tester.pump(CatalogPolicy.searchDebounce);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalog-results')), findsOneWidget);

    final gate = env.searchGate = Completer<void>();
    await tester.enterText(_field, 'synt');
    await tester.pump(CatalogPolicy.searchDebounce);
    await tester.pump();

    expect(_queries(env), ['syn', 'synt']);
    expect(find.byKey(const Key('catalog-loading-bar')), findsOneWidget);
    expect(find.byKey(const Key('catalog-results')), findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalog-loading-bar')), findsNothing);
    expect(find.byKey(const Key('catalog-results')), findsOneWidget);
  });
}
