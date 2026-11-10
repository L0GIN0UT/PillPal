import '../api/json.dart';
import 'catalog_dto.dart';

// Requests, search, GTIN lookup and sources of the catalog's public API
// (catalog/openapi.json, docs/adr/0015). Cards are in `catalog_dto.dart`.

/// Request bodies of the catalog; every lookup is a POST so that what the
/// person typed or scanned never lands in a URL (ADR 0015 §3).
abstract final class CatalogBodies {
  /// `SearchRequest`.
  static JsonMap search({
    required String q,
    required String lang,
    String? market,
    String kind = 'product',
    int? limit,
  }) {
    return {
      'q': q,
      'lang': lang,
      'kind': kind,
      if (market != null) 'market': market,
      if (limit != null) 'limit': limit,
    };
  }

  /// `GtinLookupRequest`.
  static JsonMap gtin(String gtin) => {'gtin': gtin};

  /// `ProductGetRequest`.
  static JsonMap product(String id) => {'id': id};
}

/// `SearchResult`.
class SearchResult {
  /// Creates a result.
  const SearchResult({
    required this.kind,
    required this.id,
    required this.name,
    required this.market,
    required this.substances,
    required this.withdrawn,
    this.country,
    this.manufacturer,
    this.form,
  });

  /// Reads a result.
  factory SearchResult.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return SearchResult(
      kind: reader.string('kind'),
      id: reader.string('id'),
      name: reader.string('name'),
      market: reader.string('market'),
      substances: [
        for (final item in reader.list('substances'))
          if (item is String) item,
      ],
      withdrawn: reader.boolean('withdrawn'),
      country: reader.stringOrNull('country'),
      manufacturer: reader.stringOrNull('manufacturer'),
      form: reader.stringOrNull('form'),
    );
  }

  /// Keys read from `SearchResult`.
  static const Set<String> readKeys = {
    'kind',
    'id',
    'name',
    'market',
    'substances',
    'withdrawn',
    'country',
    'manufacturer',
    'form',
  };

  /// `product` or `substance`.
  final String kind;

  /// Catalog id.
  final String id;

  /// Name.
  final String name;

  /// `ru`, `us` or `eu`.
  final String market;

  /// Names of the substances, for display.
  final List<String> substances;

  /// Whether the row left its source.
  final bool withdrawn;

  /// Country label (D6).
  final String? country;

  /// Manufacturer.
  final String? manufacturer;

  /// Dosage form.
  final String? form;
}

/// `SearchResponse`.
class SearchResponse {
  /// Creates a response.
  const SearchResponse({required this.mode, required this.results});

  /// Reads a response.
  factory SearchResponse.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return SearchResponse(
      mode: reader.string('mode'),
      results: [
        for (final item in reader.list('results'))
          SearchResult.fromJson(asJsonMap(item, 'result')),
      ],
    );
  }

  /// Keys read from `SearchResponse`.
  static const Set<String> readKeys = {'mode', 'results'};

  /// `text` or `gtin`.
  final String mode;

  /// Results in the catalog's order (own market first, D6).
  final List<SearchResult> results;
}

/// `GtinLookupResponse`.
class GtinLookup {
  /// Creates a lookup answer.
  const GtinLookup({
    required this.status,
    this.product,
    this.package,
    this.composition,
  });

  /// Reads an answer.
  factory GtinLookup.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    final product = reader.objectOrNull('product');
    final package = reader.objectOrNull('package');
    final composition = reader.objectOrNull('composition');
    return GtinLookup(
      status: reader.string('status'),
      product: product == null ? null : ProductOut.fromJson(product),
      package: package == null ? null : PackageOut.fromJson(package),
      composition:
          composition == null ? null : CompositionOut.fromJson(composition),
    );
  }

  /// Keys read from `GtinLookupResponse`.
  static const Set<String> readKeys = {
    'status',
    'product',
    'package',
    'composition',
  };

  /// `found`, `unknown`, `restricted` or `disputed`.
  final String status;

  /// The product, when found.
  final ProductOut? product;

  /// The package, when found.
  final PackageOut? package;

  /// The composition, when the product has one.
  final CompositionOut? composition;
}

/// `SourceOut`: where catalog data comes from, for Settings -> About.
class CatalogSource {
  /// Creates a source.
  const CatalogSource({
    required this.code,
    required this.name,
    required this.url,
    required this.license,
    required this.attribution,
  });

  /// Reads a source.
  factory CatalogSource.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return CatalogSource(
      code: reader.string('code'),
      name: reader.string('name'),
      url: reader.string('url'),
      license: reader.string('license'),
      attribution: reader.string('attribution'),
    );
  }

  /// Keys read from `SourceOut`.
  static const Set<String> readKeys = {
    'code',
    'name',
    'url',
    'license',
    'attribution',
  };

  /// Source code, matches `ProductOut.source`.
  final String code;

  /// Display name.
  final String name;

  /// Home page.
  final String url;

  /// License name.
  final String license;

  /// Attribution text to show.
  final String attribution;
}
