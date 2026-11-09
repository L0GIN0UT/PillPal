import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pillpal/src/data/api/api_exception.dart';
import 'package:pillpal/src/data/catalog/catalog_api.dart';
import 'package:pillpal/src/data/catalog/catalog_dto.dart';
import 'package:pillpal/src/data/catalog/catalog_search_dto.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/providers.dart';

import 'catalog_fixtures.dart';

// The catalog client is anonymous by construction (ADR 0015 §3): POST with a
// JSON body, no Authorization, no backend device id, a random install id.

typedef _Json = Map<String, Object?>;

final _Json _openapi = jsonDecode(
  File('../catalog/openapi.json').readAsStringSync(),
) as _Json;

Set<String> _properties(String name) {
  final components = _openapi['components']! as _Json;
  final schemas = components['schemas']! as _Json;
  final schema = schemas[name]! as _Json;
  return (schema['properties']! as _Json).keys.toSet();
}

void _expectReads(String schema, Set<String> keys) {
  expect(_properties(schema), containsAll(keys), reason: schema);
}

Future<ApiException> _failureOf(Future<Object?> call) async {
  try {
    await call;
  } on ApiException catch (error) {
    return error;
  }
  fail('expected an ApiException');
}

void main() {
  late CatalogTraffic traffic;
  late http.Client client;

  setUp(() {
    traffic = CatalogTraffic();
    client = recordingClient(traffic);
  });

  group('requests', () {
    test('lookups are POSTs with a JSON body and a clean URL', () async {
      final api = catalogApi(client);
      final empty = {'mode': 'text', 'results': <Object?>[]};
      final unknown = {
        'status': 'unknown',
        'product': null,
        'package': null,
        'composition': null,
      };

      traffic.respond = (r) => jsonResponse(empty);
      await api.search(q: '  Парацетамол ', lang: 'ru', market: 'ru');
      traffic.respond = (r) => jsonResponse(unknown);
      await api.lookupGtin('04600000000011');
      traffic.respond = (r) => jsonResponse(cardJson());
      await api.product(productA);

      expect(traffic.requests.map((r) => r.method), ['POST', 'POST', 'POST']);
      final paths = traffic.requests.map((r) => r.url.path);
      expect(paths, ['/v1/search', '/v1/gtins/lookup', '/v1/products/get']);
      for (final request in traffic.requests) {
        expect(request.url.hasQuery, isFalse);
        expect(request.url.toString(), isNot(contains('04600000000011')));
        expect(request.headers['Content-Type'], contains('application/json'));
      }
      final search = jsonDecode(traffic.requests.first.body) as _Json;
      expect(search['q'], 'Парацетамол', reason: 'trimmed');
      expect(search['lang'], 'ru');
      expect(search['market'], 'ru');
      expect(jsonDecode(traffic.requests[1].body), {'gtin': '04600000000011'});
      expect(jsonDecode(traffic.requests[2].body), {'id': productA});
    });

    test('no request carries credentials or the backend device id', () async {
      final api = catalogApi(client);

      traffic.respond = (r) => jsonResponse(<Object?>[]);
      await api.sources();
      traffic.respond = (r) => jsonResponse(cardJson());
      await api.product(productA);

      expect(traffic.requests.map((r) => r.method), ['GET', 'POST']);
      for (final request in traffic.requests) {
        final names = {for (final k in request.headers.keys) k.toLowerCase()};
        expect(names, isNot(contains('authorization')));
        expect(names, isNot(contains('x-device-id')));
        expect(names, isNot(contains('cookie')));
        expect(request.headers[CatalogApi.installHeader], 'install-1');
      }
      expect(traffic.requests.first.body, isEmpty);
    });

    test('a query that is too short is never sent', () async {
      final api = catalogApi(client);

      final error = await _failureOf(api.search(q: ' a ', lang: 'en'));

      expect(error.code, 'validation_error');
      expect(traffic.requests, isEmpty);
    });
  });

  group('answers', () {
    test('a card is parsed with its composition and packages', () async {
      final json = cardJson(substances: [substanceX, substanceY]);
      traffic.respond = (r) => jsonResponse(json);

      final card = await catalogApi(client).product(productA);

      expect(card.product.name, 'Synthetic Tablet');
      expect(card.composition!.complete, isTrue);
      final ids = card.composition!.ingredients.map((i) => i.substanceId);
      expect(ids, [substanceX, substanceY]);
      expect(card.packages.single.gtins, ['04600000000011']);
    });

    test('sources are read from a list', () async {
      final json = [
        {
          'code': 'fixture',
          'name': 'Fixture',
          'url': 'https://example.test',
          'license': 'CC0',
          'attribution': 'Synthetic data',
        },
      ];
      traffic.respond = (r) => jsonResponse(json);

      final sources = await catalogApi(client).sources();

      expect(sources.single.attribution, 'Synthetic data');
    });

    test('errors keep the code, status and Retry-After', () async {
      final body = jsonEncode({
        'error': {'code': 'rate_limited', 'message': 'slow down'},
      });
      traffic.respond = (r) {
        return http.Response(body, 429, headers: {'retry-after': '30'});
      };

      final error = await _failureOf(catalogApi(client).product(productA));

      expect(error.code, 'rate_limited');
      expect(error.status, 429);
      expect(error.retryAfter, const Duration(seconds: 30));
    });

    test('a network failure is a network_error', () async {
      final offline = MockClient((request) async {
        throw http.ClientException('offline');
      });

      final error = await _failureOf(catalogApi(offline).product(productA));

      expect(error.code, ApiException.networkError);
    });

    test('a wrong body shape is an invalid_response', () async {
      traffic.respond = (r) => jsonResponse(<Object?>[1, 2]);

      final error = await _failureOf(catalogApi(client).product(productA));

      expect(error.code, ApiException.invalidResponse);
    });
  });

  group('contract with catalog/openapi.json', () {
    test('request bodies use declared fields', () {
      final search = CatalogBodies.search(
        q: 'ab',
        lang: 'ru',
        market: 'ru',
        limit: 5,
      );

      expect(_properties('SearchRequest'), containsAll(search.keys));
      expect(_properties('GtinLookupRequest'), {'gtin'});
      expect(_properties('ProductGetRequest'), {'id'});
    });

    test('responses are read with declared fields', () {
      _expectReads('ProductCard', ProductCard.readKeys);
      _expectReads('ProductOut', ProductOut.readKeys);
      _expectReads('CompositionOut', CompositionOut.readKeys);
      _expectReads('IngredientOut', IngredientOut.readKeys);
      _expectReads('PackageOut', PackageOut.readKeys);
      _expectReads('RecallOut', RecallOut.readKeys);
      _expectReads('SearchResponse', SearchResponse.readKeys);
      _expectReads('SearchResult', SearchResult.readKeys);
      _expectReads('GtinLookupResponse', GtinLookup.readKeys);
      _expectReads('SourceOut', CatalogSource.readKeys);
    });
  });

  group('configuration', () {
    test('the URL of the build region is picked', () {
      const spec = 'ru=https://catalog-ru.test, eu=https://catalog-eu.test/api';

      final ru = CatalogConfig.parse(spec, region: 'ru');
      final eu = CatalogConfig.parse(spec, region: 'eu');

      expect(ru.baseUrl.toString(), 'https://catalog-ru.test');
      final search = eu.resolve('/v1/search').toString();
      expect(search, 'https://catalog-eu.test/api/v1/search');
    });

    test('without a usable URL the catalog is disabled', () {
      for (final spec in const [
        '',
        'eu=https://catalog-eu.test',
        'ru=',
        'ru=not a url',
        'ru=ftp://catalog.test',
        'garbage',
      ]) {
        expect(CatalogConfig.parse(spec, region: 'ru').enabled, isFalse);
      }
      expect(CatalogConfig.fromEnvironment(region: 'ru').enabled, isFalse);
    });

    test('the catalog API does not exist without a configured URL', () {
      final container = ProviderContainer(
        overrides: [
          catalogConfigProvider.overrideWithValue(
            const CatalogConfig.disabled(),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(catalogApiProvider), isNull);
    });
  });
}
