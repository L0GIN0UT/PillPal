import 'dart:convert';

import 'package:drift/drift.dart';

import '../api/api_exception.dart';
import '../api/json.dart';
import '../clock.dart';
import '../config.dart';
import '../db/database.dart';
import 'catalog_api.dart';
import 'catalog_dto.dart';

/// A cached card and when it was fetched.
class CachedCard {
  /// Creates a cached card.
  const CachedCard({required this.card, required this.fetchedAt});

  /// The card.
  final ProductCard card;

  /// When it was fetched from the catalog (UTC).
  final DateTime fetchedAt;
}

/// The on-device cache of catalog cards (ADR 0015 §2).
///
/// Only the card of a product a medication points at is kept, so the
/// product card and the composition hints work offline. A card is fetched
/// again only when it is opened and older than 30 days: there is no
/// background refresh, no batch and no cache of search results. Entries no
/// live medication references are evicted by the database
/// (`AppDatabase.evictUnreferencedCatalogCards`), and the whole table goes
/// with the account data.
class CatalogCacheRepository {
  /// Creates the repository. Without an [api] (the catalog is not
  /// configured) it only serves what is cached.
  CatalogCacheRepository({
    required AppDatabase db,
    required Clock clock,
    CatalogApi? api,
    Duration ttl = CatalogPolicy.cardTtl,
  })  : _db = db,
        _clock = clock,
        _api = api,
        _ttl = ttl;

  final AppDatabase _db;
  final Clock _clock;
  final CatalogApi? _api;
  final Duration _ttl;

  /// The cached card of [productId], however old, or null.
  Future<CachedCard?> cached(String productId) async {
    final query = _db.select(_db.catalogCache)
      ..where(
        (row) => row.kind.equals(catalogKindProduct) & row.id.equals(productId),
      );
    final row = await query.getSingleOrNull();
    if (row == null) {
      return null;
    }
    try {
      final json = asJsonMap(jsonDecode(row.json), 'card');
      return CachedCard(
        card: ProductCard.fromJson(json),
        fetchedAt: DateTime.fromMicrosecondsSinceEpoch(
          row.fetchedAt,
          isUtc: true,
        ),
      );
    } on FormatException {
      // A card the current parser cannot read is a miss; opening refetches.
      await _forget(productId);
      return null;
    }
  }

  /// The cached cards of [ids] (those that are cached), for the on-device
  /// matching. Never touches the network.
  Future<Map<String, ProductCard>> cardsOf(Iterable<String> ids) async {
    final cards = <String, ProductCard>{};
    for (final id in ids.toSet()) {
      final hit = await cached(id);
      if (hit != null) {
        cards[id] = hit.card;
      }
    }
    return cards;
  }

  /// Opens the card of [productId]: the cache when it is younger than the
  /// TTL, else one `POST /v1/products/get`. If that fails, the older cached
  /// card is returned (offline use); with nothing cached the failure
  /// ([ApiException]) is rethrown. Without a configured catalog only the
  /// cache is read, and null means "not cached".
  Future<ProductCard?> openCard(String productId) async {
    final hit = await cached(productId);
    final now = _clock().toUtc();
    if (hit != null && now.difference(hit.fetchedAt) < _ttl) {
      return hit.card;
    }
    final api = _api;
    if (api == null) {
      return hit?.card;
    }
    try {
      final card = await api.product(productId);
      await _store(productId, card, now);
      return card;
    } on ApiException {
      if (hit != null) {
        return hit.card;
      }
      rethrow;
    }
  }

  Future<void> _store(String productId, ProductCard card, DateTime now) {
    final table = _db.into(_db.catalogCache);
    return table.insertOnConflictUpdate(
      CatalogCacheRow(
        kind: catalogKindProduct,
        id: productId,
        json: jsonEncode(card.toJson()),
        fetchedAt: now.microsecondsSinceEpoch,
      ),
    );
  }

  Future<void> _forget(String productId) async {
    final statement = _db.delete(_db.catalogCache)
      ..where(
        (row) => row.kind.equals(catalogKindProduct) & row.id.equals(productId),
      );
    await statement.go();
  }
}
