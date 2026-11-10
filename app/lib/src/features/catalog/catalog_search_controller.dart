import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_exception.dart';
import '../../data/catalog/catalog_search_dto.dart';
import '../../data/config.dart';
import '../../data/providers.dart';
import 'catalog_providers.dart';

/// Where a catalog search stands.
enum CatalogSearchStatus {
  /// Nothing searched yet.
  idle,

  /// A request is running.
  loading,

  /// Results arrived (possibly none).
  loaded,

  /// The text is shorter than the catalog accepts; nothing was sent.
  tooShort,

  /// The catalog cannot be reached: no search until the person retries.
  offline,

  /// The catalog answered with an error.
  failed,
}

/// The state of one search sheet.
@immutable
class CatalogSearchState {
  /// Creates a state.
  const CatalogSearchState(this.status, [this.results = const []]);

  /// Where the search stands.
  final CatalogSearchStatus status;

  /// Own-market results first, the others after them (D6).
  final List<SearchResult> results;
}

/// One search sheet's requests. A search runs only when the person asks
/// (submit or the search button): there is no typing-triggered or
/// background traffic, and nothing is cached.
class CatalogSearchController extends AutoDisposeNotifier<CatalogSearchState> {
  int _generation = 0;

  @override
  CatalogSearchState build() {
    // An answer that arrives after the sheet is closed is dropped.
    ref.onDispose(() => _generation++);
    return const CatalogSearchState(CatalogSearchStatus.idle);
  }

  /// Searches [text] in [lang] (`ru` or `en`) for products, or for
  /// substances with [kind] `substance`.
  Future<void> search(
    String text, {
    required String lang,
    String kind = 'product',
  }) async {
    final query = text.trim();
    if (query.runes.length < CatalogPolicy.searchMinLength) {
      state = const CatalogSearchState(CatalogSearchStatus.tooShort);
      return;
    }
    final api = ref.read(catalogApiProvider);
    if (api == null) {
      state = const CatalogSearchState(CatalogSearchStatus.failed);
      return;
    }
    final generation = ++_generation;
    state = const CatalogSearchState(CatalogSearchStatus.loading);
    final market = ref.read(catalogOwnMarketProvider);
    try {
      final response = await api.search(
        q: query,
        lang: lang,
        kind: kind,
        market: kind == 'product' ? market : null,
      );
      if (generation == _generation) {
        state = CatalogSearchState(
          CatalogSearchStatus.loaded,
          ownMarketFirst(response.results, market),
        );
      }
    } on ApiException catch (error) {
      if (generation == _generation) {
        state = CatalogSearchState(
          error.code == ApiException.networkError
              ? CatalogSearchStatus.offline
              : CatalogSearchStatus.failed,
        );
      }
    }
  }

  /// Back to the start (the person retries after being offline).
  void reset() {
    _generation++;
    state = const CatalogSearchState(CatalogSearchStatus.idle);
  }
}

/// The search of one sheet; disposed with it.
final catalogSearchProvider =
    NotifierProvider.autoDispose<CatalogSearchController, CatalogSearchState>(
        CatalogSearchController.new);

/// [results] with those of [market] first, the rest after them, each group
/// in the catalog's order (D6).
List<SearchResult> ownMarketFirst(List<SearchResult> results, String market) {
  return [
    ...results.where((result) => result.market == market),
    ...results.where((result) => result.market != market),
  ];
}
