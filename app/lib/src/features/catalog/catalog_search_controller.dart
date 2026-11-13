import 'dart:async';

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

/// One search sheet's requests. A search runs when the person submits (or
/// taps the search button) and once they stop typing for
/// [CatalogPolicy.searchDebounce] (ADR 0015 §3). The same query is not sent
/// twice in a row, there is no background traffic, and nothing about the
/// query is logged or cached.
class CatalogSearchController extends AutoDisposeNotifier<CatalogSearchState> {
  int _generation = 0;
  Timer? _pause;

  /// What the current loading or loaded state answers (kind, language and
  /// trimmed text); a repeat of it is not sent again.
  String? _current;

  @override
  CatalogSearchState build() {
    // An answer that arrives after the sheet is closed is dropped, and a
    // search still waiting for the pause never starts.
    ref.onDispose(() {
      _generation++;
      _cancelPause();
    });
    return const CatalogSearchState(CatalogSearchStatus.idle);
  }

  /// The person typed [text]: it is searched once they pause for
  /// [CatalogPolicy.searchDebounce]. A text shorter than the catalog accepts
  /// is never sent; it clears the results (and drops an answer still on its
  /// way) instead.
  void typed(String text, {required String lang, String kind = 'product'}) {
    _cancelPause();
    if (_tooShort(text)) {
      _generation++;
      state = const CatalogSearchState(CatalogSearchStatus.idle);
      return;
    }
    if (_answers(text, lang, kind)) {
      return;
    }
    _pause = Timer(CatalogPolicy.searchDebounce, () {
      _pause = null;
      // Offline nothing is sent until the person retries.
      if (state.status != CatalogSearchStatus.offline) {
        // The search reports every outcome through the state.
        unawaited(search(text, lang: lang, kind: kind));
      }
    });
  }

  /// Whether the current state already is (or awaits) the answer to [text].
  bool _answers(String text, String lang, String kind) {
    final status = state.status;
    return (status == CatalogSearchStatus.loading ||
            status == CatalogSearchStatus.loaded) &&
        _current == _keyOf(text, lang, kind);
  }

  static String _keyOf(String text, String lang, String kind) =>
      '$kind|$lang|${text.trim()}';

  void _cancelPause() {
    _pause?.cancel();
    _pause = null;
  }

  static bool _tooShort(String text) =>
      text.trim().runes.length < CatalogPolicy.searchMinLength;

  /// Searches [text] in [lang] (`ru` or `en`) for products, or for
  /// substances with [kind] `substance`.
  Future<void> search(
    String text, {
    required String lang,
    String kind = 'product',
  }) async {
    _cancelPause();
    if (_answers(text, lang, kind)) {
      return;
    }
    // Every call supersedes the one before, also when it ends early: an
    // answer to an earlier request must not overwrite this state.
    final generation = ++_generation;
    final query = text.trim();
    if (_tooShort(query)) {
      state = const CatalogSearchState(CatalogSearchStatus.tooShort);
      return;
    }
    final api = ref.read(catalogApiProvider);
    if (api == null) {
      state = const CatalogSearchState(CatalogSearchStatus.failed);
      return;
    }
    _current = _keyOf(query, lang, kind);
    // The earlier results stay on screen while the next ones load.
    state = CatalogSearchState(CatalogSearchStatus.loading, state.results);
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
    } on Object catch (error) {
      if (generation == _generation) {
        _fail(error);
      }
    }
  }

  /// A network error is offline; anything else, expected or not, is a
  /// failed search, never a stuck spinner.
  void _fail(Object error) {
    final offline =
        error is ApiException && error.code == ApiException.networkError;
    if (offline) {
      // A pause still running must not search a network known to be down
      // (the field is disabled until the person retries).
      _cancelPause();
    }
    state = CatalogSearchState(
      offline ? CatalogSearchStatus.offline : CatalogSearchStatus.failed,
    );
  }

  /// Back to the start (the person retries after being offline).
  void reset() {
    _cancelPause();
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
