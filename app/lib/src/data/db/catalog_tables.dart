import 'package:drift/drift.dart';

/// Cards of the catalog products the account's medications point at, so
/// the product card and the composition hints work offline (ADR 0015 §2).
///
/// It reveals medications, so it lives and dies with them: cleared by
/// `AppDatabase.wipeAccountData`, evicted with a scope, and entries no live
/// medication references are dropped. Search results are never cached.
@DataClassName('CatalogCacheRow')
class CatalogCache extends Table {
  /// What [id] identifies; `product` (a whole `ProductCard`) today.
  TextColumn get kind => text()();

  /// Catalog id of the cached object.
  TextColumn get id => text()();

  /// The card JSON the catalog sent (it parsed when it was stored).
  TextColumn get json => text()();

  /// When the card was fetched (microseconds, UTC); the 30-day TTL counts
  /// from it.
  IntColumn get fetchedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {kind, id};
}

/// The `kind` of a whole product card.
const String catalogKindProduct = 'product';
