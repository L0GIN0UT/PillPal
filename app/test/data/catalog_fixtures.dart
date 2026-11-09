import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pillpal/src/data/catalog/catalog_api.dart';
import 'package:pillpal/src/data/config.dart';

// Synthetic catalog answers and a recording HTTP client for the catalog tests.

const String productA = '5b0f4a52-8e1b-4f60-9d3b-0a2f3c9d1e11';
const String productB = '6c1a5b63-9f2c-4a71-8e4c-1b3a4d0e2f22';
const String compositionA = '8e3c7d85-1b4e-4c93-8a6e-3d5c6f2a4b44';
const String substanceX = '9f4d8e96-2c5f-4da4-9b7f-4e6d7a3b5c55';
const String substanceY = 'a05e9fa7-3d60-4eb5-8c80-5f7e8b4c6d66';

/// A `ProductCard` JSON.
Map<String, Object?> cardJson({
  String productId = productA,
  String? compositionId = compositionA,
  bool complete = true,
  List<String> substances = const [substanceX],
}) {
  Map<String, Object?>? composition;
  if (compositionId != null) {
    composition = {
      'id': compositionId,
      'complete': complete,
      'withdrawn': false,
      'form_code': null,
      'form_name_ru': 'таблетки',
      'form_name_en': 'tablets',
      'ingredients': [
        for (final id in substances)
          {
            'substance_id': id,
            'name_ru': 'Вещество',
            'name_en': 'Substance',
            'strength_value': '500',
            'strength_unit': 'mg',
            'per_value': null,
            'per_unit': null,
          },
      ],
    };
  }
  return {
    'product': {
      'id': productId,
      'name': 'Synthetic Tablet',
      'market': 'ru',
      'country': 'RU',
      'manufacturer': 'Synthetic Maker',
      'registration_number': null,
      'rx_status': null,
      'source': 'fixture',
      'withdrawn': false,
    },
    'composition': composition,
    'packages': [
      {
        'id': '7d2b6c74-0a3d-4b82-9f5d-2c4b5e1f3a33',
        'gtins': ['04600000000011'],
        'count': '30',
        'count_unit': 'tablet',
        'description': null,
        'withdrawn': false,
      },
    ],
    'recalls': <Object?>[],
  };
}

/// The requests a [recordingClient] saw.
class CatalogTraffic {
  /// Every request, in order.
  final List<http.Request> requests = [];

  /// The answer for the next request; defaults to a synthetic card.
  http.Response Function(http.Request request) respond = _defaultCard;
}

http.Response _defaultCard(http.Request request) => jsonResponse(cardJson());

/// A JSON response with the headers the catalog sends.
http.Response jsonResponse(Object? body, {int status = 200}) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: {
      'content-type': 'application/json',
      'cache-control': 'no-store',
    },
  );
}

/// A client that records everything and answers with `traffic.respond`.
MockClient recordingClient(CatalogTraffic traffic) {
  return MockClient((request) async {
    traffic.requests.add(request);
    return traffic.respond(request);
  });
}

/// A catalog client at `https://catalog.test` with install id [installId].
CatalogApi catalogApi(
  http.Client client, {
  String installId = 'install-1',
}) {
  return CatalogApi(
    httpClient: client,
    config: CatalogConfig(baseUrl: Uri.parse('https://catalog.test')),
    installId: () async => installId,
  );
}
