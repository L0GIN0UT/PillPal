import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../data/catalog_fixtures.dart';
import '../helpers.dart';
import 'catalog_ui_env.dart';

// The catalog search in the medication form (ADR 0015 §3, §5): hidden
// without a catalog, nothing sent until the person submits, offline says so,
// and foreign-market results come after the own market, labelled (D6).

void main() {
  testWidgets('without a catalog URL no catalog UI exists', (tester) async {
    final env = CatalogUiEnv();
    final container = await env.pump(tester, withCatalog: false);
    await env.openNewForm(tester);

    expect(find.byKey(const Key('med-name')), findsOneWidget);
    expect(find.byKey(const Key('med-catalog')), findsNothing);
    expect(find.byKey(const Key('med-scan')), findsNothing);
    expect(find.byKey(const Key('manual-ing-add')), findsNothing);

    goRoute(container, AppRoutes.settings);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-catalog-sources')), findsNothing);
    expect(env.traffic.requests, isEmpty);
  });

  testWidgets('a medication linked earlier keeps its link without a catalog',
      (tester) async {
    final env = CatalogUiEnv();
    final container = await env.pump(tester, withCatalog: false);
    final id = await env.seedLinked(container);

    openRoute(container, AppRoutes.medication(id));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalog-linked')), findsNothing);
    await tester.enterText(find.byKey(const Key('med-name')), 'Renamed');
    await env.save(tester);

    final row =
        (await env.harness.db.select(env.harness.db.medications).get()).single;
    expect(row.name, 'Renamed');
    expect(row.catalogProductId, productA);
    expect(row.catalogCompositionId, compositionA);
  });

  testWidgets('typing sends nothing; a one-letter search is not sent',
      (tester) async {
    final env = CatalogUiEnv();
    await env.pump(tester);
    await env.openNewForm(tester);

    await tester.tap(find.byKey(const Key('med-catalog')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('catalog-search-text')), 'sy');
    await tester.pump();
    expect(env.traffic.requests, isEmpty);

    await tester.enterText(find.byKey(const Key('catalog-search-text')), 's');
    await tester.tap(find.byKey(const Key('catalog-search-go')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('catalog-too-short')), findsOneWidget);
    expect(env.traffic.requests, isEmpty);
  });

  testWidgets('offline shows the hint and offers no search', (tester) async {
    final env = CatalogUiEnv()..catalogOffline = true;
    await env.pump(tester);
    await env.openNewForm(tester);

    await env.search(tester, 'synthetic');

    expect(find.byKey(const Key('catalog-offline')), findsOneWidget);
    expect(find.byKey(const Key('catalog-results')), findsNothing);
    expect(
      tester.widget<TextField>(find.byKey(const Key('catalog-search-text'))),
      isA<TextField>().having((field) => field.enabled, 'enabled', isFalse),
    );
    final go = tester.widget<IconButton>(
      find.byKey(const Key('catalog-search-go')),
    );
    expect(go.onPressed, isNull);

    // Back online, a retry brings the search back.
    env.catalogOffline = false;
    await tester.tap(find.byKey(const Key('catalog-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalog-offline')), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('catalog-search-text')))
          .enabled,
      isTrue,
    );
  });

  testWidgets('foreign-market results follow the own market, labelled',
      (tester) async {
    final env = CatalogUiEnv()
      ..results = [
        searchResultJson(id: 'us-1', market: 'us', country: 'US'),
        searchResultJson(id: 'ru-1', name: 'Own market tablet'),
        searchResultJson(id: 'eu-1', market: 'eu', country: 'DE'),
        searchResultJson(id: 'ru-2', name: 'Another own', withdrawn: true),
      ];
    await env.pump(tester);
    await env.openNewForm(tester);

    await env.search(tester, 'tablet');

    double top(String id) =>
        tester.getTopLeft(find.byKey(ValueKey('catalog-result-$id'))).dy;
    expect(top('ru-1'), lessThan(top('ru-2')));
    expect(top('ru-2'), lessThan(top('us-1')));
    expect(top('us-1'), lessThan(top('eu-1')));
    expect(find.text('Country: US'), findsOneWidget);
    expect(find.text('Country: DE'), findsOneWidget);
    expect(find.byKey(const ValueKey('catalog-country-ru-1')), findsNothing);
    expect(
      find.byKey(const ValueKey('catalog-withdrawn-ru-2')),
      findsOneWidget,
    );
    // The request asks for the own market first and carries no account.
    final request = env.traffic.requests.single;
    expect(request.url.path, '/v1/search');
    expect(request.headers.containsKey('Authorization'), isFalse);
  });

  testWidgets('an empty answer says so and keeps manual entry open',
      (tester) async {
    final env = CatalogUiEnv();
    await env.pump(tester);
    await env.openNewForm(tester);

    await env.search(tester, 'nothing like it');

    expect(find.byKey(const Key('catalog-empty')), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('med-name')), findsOneWidget);
  });
}
