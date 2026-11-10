import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/catalog/catalog_dto.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/routing/routes.dart';
import 'package:pillpal/src/settings/app_settings.dart';

import '../data/catalog_fixtures.dart';
import '../family/family_fixtures.dart' show seedForeignMedication, seedProfile;
import '../helpers.dart';
import 'catalog_ui_env.dart';

// The product card (ADR 0015 §2, §5): from the cache offline, with the
// source attribution and a withdrawn label; the sources screen; nothing for
// a redacted medication; and the whole flow at the largest text scale.

Future<void> _openCard(
  WidgetTester tester,
  ProviderContainer container,
  String id,
) async {
  openRoute(container, AppRoutes.medication(id));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('catalog-open-card')));
  await tester.pumpAndSettle();
}

Future<void> _cache(ProviderContainer container, Map<String, Object?> json) {
  return container
      .read(catalogCacheRepositoryProvider)
      .remember(ProductCard.fromJson(json));
}

void main() {
  group('product card', () {
    testWidgets('comes from the cache offline, withdrawn and unattributed',
        (tester) async {
      final env = CatalogUiEnv();
      final container = await env.pump(tester);
      final id = await env.seedLinked(container);
      final card = cardJson();
      (card['product']! as Map<String, Object?>)['withdrawn'] = true;
      await _cache(container, card);
      env.catalogOffline = true;

      await _openCard(tester, container, id);

      expect(find.byKey(const Key('product-card-name')), findsOneWidget);
      expect(find.text('Synthetic Tablet'), findsWidgets);
      expect(find.byKey(const Key('product-card-withdrawn')), findsOneWidget);
      expect(find.text('No longer listed by the source'), findsOneWidget);
      expect(find.text('Catalog data may be incomplete.'), findsOneWidget);
      expect(find.text('Source: fixture'), findsOneWidget);
      expect(find.byKey(const Key('product-card-attribution')), findsNothing);
      expect(find.text('Manufacturer: Synthetic Maker'), findsOneWidget);
      expect(find.text('Substance 500 mg'), findsOneWidget);
    });

    testWidgets('names its source and shows the attribution online',
        (tester) async {
      final env = CatalogUiEnv()..sources = [sourceJson()];
      final container = await env.pump(tester);
      final id = await env.seedLinked(container);

      await _openCard(tester, container, id);

      expect(find.text('Source: Fixture Source'), findsOneWidget);
      expect(
        find.text('Data courtesy of the fixture source.'),
        findsOneWidget,
      );
      // A fresh cached card is not fetched again; only the sources are.
      expect(
        env.traffic.requests.map((request) => request.url.path),
        ['/v1/sources'],
      );
    });

    testWidgets('an incomplete composition says so', (tester) async {
      final env = CatalogUiEnv();
      final container = await env.pump(tester);
      final id = await env.seedLinked(container);
      await _cache(container, cardJson(complete: false));

      await _openCard(tester, container, id);

      expect(find.byKey(const Key('product-card-incomplete')), findsOneWidget);
    });

    testWidgets('not cached and offline: says so instead of failing',
        (tester) async {
      final env = CatalogUiEnv();
      final container = await env.pump(tester);
      final id = await container.read(medicationsRepositoryProvider).create(
            profileId: selfProfileId,
            draft: const MedicationDraft(
              name: 'No card yet',
              catalogLink: CatalogUiEnv.defaultLink,
            ),
          );
      env.catalogOffline = true;

      await _openCard(tester, container, id);

      expect(find.byKey(const Key('product-card-offline')), findsOneWidget);
    });

    testWidgets('a redacted medication shows no card and no catalog UI',
        (tester) async {
      final env = CatalogUiEnv();
      final container = await env.pump(tester);
      final profile = await seedProfile(env.harness, role: 'editor');
      final seeded = await seedForeignMedication(
        env.harness,
        container,
        profile,
        privacy: 'anonymous',
        redacted: true,
      );

      openRoute(container, AppRoutes.medication(seeded.medication));
      await tester.pumpAndSettle();

      expect(find.text('You cannot change this medication.'), findsOneWidget);
      expect(find.byKey(const Key('catalog-linked')), findsNothing);
      expect(find.byKey(const Key('med-catalog')), findsNothing);
      expect(find.byKey(const Key('catalog-open-card')), findsNothing);
    });
  });

  group('sources screen', () {
    testWidgets('lists each source with its attribution and license',
        (tester) async {
      final env = CatalogUiEnv()..sources = [sourceJson()];
      final container = await env.pump(tester);

      goRoute(container, AppRoutes.settings);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('settings-catalog-sources')),
      );
      await tester.tap(find.byKey(const Key('settings-catalog-sources')));
      await tester.pumpAndSettle();

      expect(
          find.byKey(const ValueKey('catalog-source-fixture')), findsOneWidget);
      expect(
        find.text('Data courtesy of the fixture source.'),
        findsOneWidget,
      );
      expect(find.text('License: CC0'), findsOneWidget);
    });

    testWidgets('offline says the list needs a connection; retry works',
        (tester) async {
      final env = CatalogUiEnv()
        ..sources = [sourceJson()]
        ..catalogOffline = true;
      final container = await env.pump(tester);

      goRoute(container, AppRoutes.catalogSources);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('catalog-sources-offline')), findsOneWidget);

      env.catalogOffline = false;
      await tester.tap(find.byKey(const Key('catalog-sources-retry')));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('catalog-source-fixture')), findsOneWidget);
    });
  });

  testWidgets('the whole flow lays out at the largest text scale',
      (tester) async {
    // The largest system scale; senior mode (x1.3) goes on top of it.
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final env = CatalogUiEnv()
      ..sources = [sourceJson()]
      ..cards[productB] = cardJson(
        productId: productB,
        compositionId: 'a16f0ab8-4e71-4fc6-8d91-6a8f9c5d7e77',
      )
      ..results = [
        searchResultJson(id: productB, name: 'Other brand', substances: [
          'Substance',
          'A very long substance name that has to wrap on a small screen',
        ]),
        searchResultJson(id: 'us-1', market: 'us', country: 'US'),
      ];
    final container = await env.pump(
      tester,
      locale: const Locale('ru'),
      configure: (scope) {
        scope.read(settingsProvider.notifier)
          ..setSeniorMode(enabled: true)
          ..setThemeMode(ThemeMode.dark);
      },
    );
    await env.seedLinked(container);
    await env.openNewForm(tester);
    await tester.enterText(find.byKey(const Key('med-name')), 'Моё название');

    await env.searchAndPick(tester, 'синтетика', productB);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('catalog-overlap')), findsOneWidget);
    expect(find.byKey(const ValueKey('catalog-offer-name')), findsOneWidget);
    expect(find.byKey(const Key('catalog-consent')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('catalog-open-card')));
    await tester.tap(find.byKey(const Key('catalog-open-card')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('product-card-name')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
