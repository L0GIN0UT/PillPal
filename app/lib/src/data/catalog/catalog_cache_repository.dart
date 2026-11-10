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
  final Map<String, Future<ProductCard?>> _opening = {};

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
    return _parse(row);
  }

  /// The cached cards of [ids] (those that are cached), for the on-device
  /// matching, in one query. Never touches the network.
  Future<Map<String, ProductCard>> cardsOf(Iterable<String> ids) async {
    final wanted = ids.toSet();
    final query = _db.select(_db.catalogCache)
      ..where(
        (row) => row.kind.equals(catalogKindProduct) & row.id.isIn(wanted),
      );
    final cards = <String, ProductCard>{};
    for (final row in await query.get()) {
      final hit = await _parse(row);
      if (hit != null) {
        cards[row.id] = hit.card;
      }
    }
    return cards;
  }

  /// Opens the card of [productId]: the cache when it is younger than the
  /// TTL, else one `POST /v1/products/get`. If that fails (offline, or an
  /// answer that does not parse), the older cached card is returned; with
  /// nothing cached the failure ([ApiException]) is rethrown. Without a
  /// configured catalog only the cache is read, and null means "not
  /// cached". Concurrent opens of one card share one request. A fetched
  /// card is stored only while a live medication references it.
  Future<ProductCard?> openCard(String productId) {
    final running = _opening[productId];
    if (running != null) {
      return running;
    }
    final started = _open(productId);
    _opening[productId] = started;
    return started.whenComplete(() {
      _opening.remove(productId);
    });
  }

  /// Keeps [card], which the form that just linked it has in hand, so the
  /// product card works offline without a second request. Stored only while
  /// a live medication references the product (same rule as [openCard]).
  Future<void> remember(ProductCard card) {
    return _storeIfReferenced(card.product.id, card, _clock().toUtc());
  }

  Future<ProductCard?> _open(String productId) async {
    final hit = await cached(productId);
    final now = _clock().toUtc();
    if (hit != null && _isFresh(hit.fetchedAt, now)) {
      return hit.card;
    }
    final api = _api;
    if (api == null) {
      return hit?.card;
    }
    try {
      final card = await api.product(productId);
      await _storeIfReferenced(productId, card, now);
      return card;
    } on ApiException {
      if (hit != null) {
        return hit.card;
      }
      rethrow;
    }
  }

  /// A fetch time in the future (a device clock that was ahead) is stale.
  bool _isFresh(DateTime fetchedAt, DateTime now) {
    final age = now.difference(fetchedAt);
    return !age.isNegative && age < _ttl;
  }

  Future<CachedCard?> _parse(CatalogCacheRow row) async {
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
      await _forget(row.id);
      return null;
    }
  }

  /// One statement, so the check and the insert cannot be separated by a
  /// wipe: a response that arrives after sign-out (no medication left), or
  /// for a product no medication points at, is not stored.
  Future<void> _storeIfReferenced(
    String productId,
    ProductCard card,
    DateTime now,
  ) {
    return _db.customInsert(
      'INSERT OR REPLACE INTO catalog_cache (kind, id, json, fetched_at) '
      'SELECT ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM medications '
      'WHERE catalog_product_id = ? AND deleted_at IS NULL)',
      variables: [
        Variable.withString(catalogKindProduct),
        Variable.withString(productId),
        Variable.withString(jsonEncode(card.toJson())),
        Variable.withInt(now.microsecondsSinceEpoch),
        Variable.withString(productId),
      ],
      updates: {_db.catalogCache},
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
