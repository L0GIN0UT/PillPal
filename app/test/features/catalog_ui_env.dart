import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pillpal/src/data/catalog/catalog_dto.dart';
import 'package:pillpal/src/data/catalog/catalog_link.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';

import '../data/catalog_fixtures.dart';
import '../helpers.dart';

// A fake catalog and backend for the catalog UI tests: the catalog answers
// search, card and sources requests from the fields below, and the backend
// answers `GET /v1/me/features`. Everything is synthetic.

/// A `SearchResult` JSON.
Map<String, Object?> searchResultJson({
  required String id,
  String name = 'Synthetic Tablet',
  String market = 'ru',
  String? country,
  String kind = 'product',
  List<String> substances = const ['Substance'],
  bool withdrawn = false,
}) {
  return {
    'kind': kind,
    'id': id,
    'name': name,
    'market': market,
    'country': country,
    'substances': substances,
    'withdrawn': withdrawn,
    'manufacturer': 'Synthetic Maker',
    'form': 'tablets',
  };
}

/// A `SourceOut` JSON.
Map<String, Object?> sourceJson({String code = 'fixture'}) {
  return {
    'code': code,
    'name': 'Fixture Source',
    'url': 'https://fixture.test',
    'license': 'CC0',
    'attribution': 'Data courtesy of the fixture source.',
  };
}

/// The fake services of one test.
class CatalogUiEnv {
  /// Creates the environment; the catalog knows [productA] by default.
  CatalogUiEnv() {
    cards[productA] = cardJson();
  }

  /// Every request the catalog saw.
  final CatalogTraffic traffic = CatalogTraffic();

  /// Whether the catalog cannot be reached.
  bool catalogOffline = false;

  /// Whether the backend cannot be reached.
  bool backendOffline = false;

  /// `catalog_contributions_enabled` of the backend.
  bool contributions = true;

  /// What a product search returns, in the catalog's order.
  List<Map<String, Object?>> results = [];

  /// What a substance search returns.
  List<Map<String, Object?>> substanceResults = [];

  /// Cards by product id.
  final Map<String, Map<String, Object?>> cards = {};

  /// Attribution of the sources.
  List<Map<String, Object?>> sources = [];

  late final TestHarness harness = TestHarness(handler: _backend);

  Future<http.Response> _backend(http.Request request) async {
    if (backendOffline) {
      throw http.ClientException('offline');
    }
    if (request.url.path == '/v1/me/features') {
      return jsonResponse({
        'soft_limits_enabled': false,
        'relatives_limit': null,
        'pdf_reports_limit': null,
        'catalog_contributions_enabled': contributions,
      });
    }
    return http.Response('', 503);
  }

  http.Response _catalog(http.Request request) {
    switch (request.url.path) {
      case '/v1/search':
        final body = jsonDecode(request.body) as Map<String, Object?>;
        final found = body['kind'] == 'substance' ? substanceResults : results;
        return jsonResponse({'mode': 'text', 'results': found});
      case '/v1/products/get':
        final body = jsonDecode(request.body) as Map<String, Object?>;
        final card = cards[body['id']];
        return card == null
            ? jsonResponse({
                'error': {'code': 'not_found', 'message': 'not found'},
              }, status: 404)
            : jsonResponse(card);
      case '/v1/sources':
        return jsonResponse(sources);
    }
    return http.Response('', 404);
  }

  /// The overrides that give the app this catalog.
  List<Override> get overrides {
    final client = MockClient((request) async {
      traffic.requests.add(request);
      if (catalogOffline) {
        throw http.ClientException('offline');
      }
      return _catalog(request);
    });
    return [
      catalogConfigProvider.overrideWithValue(
        CatalogConfig(baseUrl: Uri.parse('https://catalog.test')),
      ),
      catalogApiProvider.overrideWithValue(catalogApi(client)),
    ];
  }

  /// Seeds the own profile and pumps the app with this catalog.
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    bool withCatalog = true,
    void Function(ProviderContainer container)? configure,
  }) async {
    final container = createContainer(
      harness,
      overrides: withCatalog ? overrides : const [],
    );
    await harness.seedSelfProfile();
    return pumpWith(tester, container, locale, configure: configure);
  }

  /// Pumps the app on an already prepared [container].
  Future<ProviderContainer> pumpWith(
    WidgetTester tester,
    ProviderContainer container,
    Locale locale, {
    void Function(ProviderContainer container)? configure,
  }) {
    return pumpApp(
      tester,
      harness: harness,
      container: container,
      locale: locale,
      configure: configure,
    );
  }

  /// A medication of the own profile linked to [productA] with its card
  /// cached, as after a save in the form; returns its id.
  Future<String> seedLinked(
    ProviderContainer container, {
    String name = 'Existing',
    CatalogLink? link,
    String? stockCount,
  }) async {
    final id = await container.read(medicationsRepositoryProvider).create(
          profileId: selfProfileId,
          draft: MedicationDraft(
            name: name,
            stockCount: stockCount,
            stockUnit: stockCount == null ? null : 'tablet',
            catalogLink: link ?? defaultLink,
          ),
        );
    final card = ProductCard.fromJson(cardJson());
    await container.read(catalogCacheRepositoryProvider).remember(card);
    return id;
  }

  /// The references of [productA]'s only package.
  static const CatalogLink defaultLink = CatalogLink(
    productId: productA,
    packageId: '7d2b6c74-0a3d-4b82-9f5d-2c4b5e1f3a33',
    compositionId: compositionA,
    gtin: shareableGtin,
  );

  /// Opens the form of a new medication from Today.
  Future<void> openNewForm(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('today-add')));
    await tester.pumpAndSettle();
  }

  /// Types [text] in the open search sheet and submits it.
  Future<void> search(WidgetTester tester, String text) async {
    await tester.tap(find.byKey(const Key('med-catalog')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('catalog-search-text')), text);
    await tester.tap(find.byKey(const Key('catalog-search-go')));
    await tester.pumpAndSettle();
  }

  /// Searches [text] and taps the result [id].
  Future<void> searchAndPick(
    WidgetTester tester,
    String text,
    String id,
  ) async {
    await search(tester, text);
    await tester.tap(find.byKey(ValueKey('catalog-result-$id')));
    await tester.pumpAndSettle();
  }

  /// Taps save and settles.
  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('med-save')));
    await tester.pumpAndSettle();
  }

  /// The decoded payload of the last medication write in the outbox.
  Future<Map<String, Object?>> lastMedicationPayload() async {
    final rows = await (harness.db.select(harness.db.outbox)
          ..where((row) => row.entityKind.equals('medication')))
        .get();
    return jsonDecode(rows.last.payload!) as Map<String, Object?>;
  }
}
