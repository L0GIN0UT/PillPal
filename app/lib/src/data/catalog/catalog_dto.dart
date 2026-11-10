import '../api/json.dart';

// The public API of the global catalog service (catalog/openapi.json,
// docs/adr/0015). Keys read here are declared so that the contract test can
// check them against the snapshot. Requests carry no account data.

/// `IngredientOut`.
class IngredientOut {
  /// Creates an ingredient.
  const IngredientOut({
    required this.substanceId,
    this.nameRu,
    this.nameEn,
    this.strengthValue,
    this.strengthUnit,
    this.perValue,
    this.perUnit,
  });

  /// Reads an ingredient.
  factory IngredientOut.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return IngredientOut(
      substanceId: reader.string('substance_id'),
      nameRu: reader.stringOrNull('name_ru'),
      nameEn: reader.stringOrNull('name_en'),
      strengthValue: reader.stringOrNull('strength_value'),
      strengthUnit: reader.stringOrNull('strength_unit'),
      perValue: reader.stringOrNull('per_value'),
      perUnit: reader.stringOrNull('per_unit'),
    );
  }

  /// Keys read from `IngredientOut`.
  static const Set<String> readKeys = {
    'substance_id',
    'name_ru',
    'name_en',
    'strength_value',
    'strength_unit',
    'per_value',
    'per_unit',
  };

  /// Catalog substance id: what the overlap hint compares.
  final String substanceId;

  /// Russian name.
  final String? nameRu;

  /// English name.
  final String? nameEn;

  /// Strength amount as a decimal string.
  final String? strengthValue;

  /// Strength unit.
  final String? strengthUnit;

  /// Denominator amount of the strength (e.g. per 5 ml).
  final String? perValue;

  /// Denominator unit.
  final String? perUnit;
}

/// `CompositionOut`.
class CompositionOut {
  /// Creates a composition.
  const CompositionOut({
    required this.id,
    required this.complete,
    required this.withdrawn,
    required this.ingredients,
    this.formCode,
    this.formNameRu,
    this.formNameEn,
  });

  /// Reads a composition.
  factory CompositionOut.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return CompositionOut(
      id: reader.string('id'),
      complete: reader.boolean('complete'),
      withdrawn: reader.boolean('withdrawn'),
      formCode: reader.stringOrNull('form_code'),
      formNameRu: reader.stringOrNull('form_name_ru'),
      formNameEn: reader.stringOrNull('form_name_en'),
      ingredients: [
        for (final item in reader.list('ingredients'))
          IngredientOut.fromJson(asJsonMap(item, 'ingredient')),
      ],
    );
  }

  /// Keys read from `CompositionOut`.
  static const Set<String> readKeys = {
    'id',
    'complete',
    'withdrawn',
    'form_code',
    'form_name_ru',
    'form_name_en',
    'ingredients',
  };

  /// Catalog composition id.
  final String id;

  /// Whether every ingredient has a structured strength (ADR 0012 §1).
  final bool complete;

  /// Whether the row left its source.
  final bool withdrawn;

  /// Dosage form code.
  final String? formCode;

  /// Russian dosage form name.
  final String? formNameRu;

  /// English dosage form name.
  final String? formNameEn;

  /// Ingredients.
  final List<IngredientOut> ingredients;
}

/// `PackageOut`.
class PackageOut {
  /// Creates a package.
  const PackageOut({
    required this.id,
    required this.gtins,
    required this.withdrawn,
    this.count,
    this.countUnit,
    this.description,
  });

  /// Reads a package.
  factory PackageOut.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return PackageOut(
      id: reader.string('id'),
      gtins: [
        for (final item in reader.list('gtins'))
          if (item is String) item,
      ],
      withdrawn: reader.boolean('withdrawn'),
      count: reader.stringOrNull('count'),
      countUnit: reader.stringOrNull('count_unit'),
      description: reader.stringOrNull('description'),
    );
  }

  /// Keys read from `PackageOut`.
  static const Set<String> readKeys = {
    'id',
    'gtins',
    'withdrawn',
    'count',
    'count_unit',
    'description',
  };

  /// Catalog package id.
  final String id;

  /// GTIN-14s of the package.
  final List<String> gtins;

  /// Whether the row left its source.
  final bool withdrawn;

  /// Units per pack as a decimal string.
  final String? count;

  /// Unit of [count].
  final String? countUnit;

  /// Source description of the pack.
  final String? description;
}

/// `ProductOut`.
class ProductOut {
  /// Creates a product.
  const ProductOut({
    required this.id,
    required this.name,
    required this.market,
    required this.source,
    required this.withdrawn,
    this.country,
    this.manufacturer,
    this.registrationNumber,
    this.rxStatus,
  });

  /// Reads a product.
  factory ProductOut.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return ProductOut(
      id: reader.string('id'),
      name: reader.string('name'),
      market: reader.string('market'),
      source: reader.string('source'),
      withdrawn: reader.boolean('withdrawn'),
      country: reader.stringOrNull('country'),
      manufacturer: reader.stringOrNull('manufacturer'),
      registrationNumber: reader.stringOrNull('registration_number'),
      rxStatus: reader.stringOrNull('rx_status'),
    );
  }

  /// Keys read from `ProductOut`.
  static const Set<String> readKeys = {
    'id',
    'name',
    'market',
    'source',
    'withdrawn',
    'country',
    'manufacturer',
    'registration_number',
    'rx_status',
  };

  /// Catalog product id.
  final String id;

  /// Brand name.
  final String name;

  /// `ru`, `us` or `eu`.
  final String market;

  /// Source code, the key of the attribution in `GET /v1/sources`.
  final String source;

  /// Whether the row left its source (the link stays).
  final bool withdrawn;

  /// Country label.
  final String? country;

  /// Manufacturer.
  final String? manufacturer;

  /// Registration number.
  final String? registrationNumber;

  /// Prescription status as the source states it.
  final String? rxStatus;
}

/// `RecallOut`.
class RecallOut {
  /// Creates a recall.
  const RecallOut({
    required this.source,
    required this.series,
    required this.reasonCode,
    this.publishedAt,
  });

  /// Reads a recall.
  factory RecallOut.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return RecallOut(
      source: reader.string('source'),
      series: reader.string('series'),
      reasonCode: reader.string('reason_code'),
      publishedAt: reader.stringOrNull('published_at'),
    );
  }

  /// Keys read from `RecallOut`.
  static const Set<String> readKeys = {
    'source',
    'series',
    'reason_code',
    'published_at',
  };

  /// Source of the recall flag.
  final String source;

  /// Recalled series.
  final String series;

  /// Reason code.
  final String reasonCode;

  /// Publication date as the source gives it.
  final String? publishedAt;
}

/// `ProductCard`: a product with its composition, packages and recalls.
/// It is what the device caches (ADR 0015 §2), so it keeps the received
/// JSON for [toJson].
class ProductCard {
  const ProductCard._({
    required this.product,
    required this.composition,
    required this.packages,
    required this.recalls,
    required JsonMap json,
  }) : _json = json;

  /// Reads a card.
  factory ProductCard.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    final composition = reader.objectOrNull('composition');
    return ProductCard._(
      product: ProductOut.fromJson(reader.object('product')),
      composition:
          composition == null ? null : CompositionOut.fromJson(composition),
      packages: [
        for (final item in reader.list('packages'))
          PackageOut.fromJson(asJsonMap(item, 'package')),
      ],
      recalls: [
        for (final item in reader.list('recalls'))
          RecallOut.fromJson(asJsonMap(item, 'recall')),
      ],
      json: json,
    );
  }

  /// Keys read from `ProductCard`.
  static const Set<String> readKeys = {
    'product',
    'composition',
    'packages',
    'recalls',
  };

  /// The product.
  final ProductOut product;

  /// Its composition; null for a product without one.
  final CompositionOut? composition;

  /// Its packages.
  final List<PackageOut> packages;

  /// Recall flags.
  final List<RecallOut> recalls;

  final JsonMap _json;

  /// The JSON as received, for the cache.
  JsonMap toJson() => _json;
}
