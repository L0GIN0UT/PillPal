import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../data/api/api_exception.dart';
import '../../data/catalog/catalog_dto.dart';
import '../../data/catalog/catalog_link.dart';
import '../../data/catalog/catalog_search_dto.dart';
import '../../data/catalog/composition_inputs.dart';
import '../../data/db/database.dart';
import '../../data/providers.dart';
import '../doses/dose_providers.dart';
import 'catalog_fill.dart';

/// Whether this build has a catalog; all catalog UI hangs on it (without
/// `PILLPAL_CATALOG_URLS` there is no search, no card, no hint).
final catalogEnabledProvider = Provider<bool>(
  (ref) => ref.watch(catalogConfigProvider).enabled,
);

/// The data market of this build's region (`ru` or `eu`): its products are
/// listed before the others (D6).
final catalogOwnMarketProvider = Provider<String>(
  (ref) => ref.watch(apiConfigProvider).region,
);

/// The card of a product: the cache while it is fresh, else the catalog
/// (ADR 0015 §2); an [ApiException] when it is offline with nothing cached.
final catalogCardProvider =
    FutureProvider.autoDispose.family<ProductCard?, String>(
  (ref, productId) =>
      ref.watch(catalogCacheRepositoryProvider).openCard(productId),
);

/// Attribution of the catalog's sources (`GET /v1/sources`).
final catalogSourcesProvider =
    FutureProvider.autoDispose<List<CatalogSource>>((ref) async {
  final api = ref.watch(catalogApiProvider);
  if (api == null) {
    return const <CatalogSource>[];
  }
  return api.sources();
});

/// Whether the opt-in to count a (GTIN, product) link can be recorded now.
enum ContributionsAvailability {
  /// Online and the server accepts contributions.
  available,

  /// The server could not be reached.
  offline,

  /// The server does not accept contributions: the box is not shown.
  disabled,

  /// The server answered with something unusable (an error, no session):
  /// the box is not shown either.
  unknown,
}

/// `FeaturesOut.catalog_contributions_enabled`, asked when the box is
/// shown; a consent is never recorded blind.
final contributionsAvailabilityProvider =
    FutureProvider.autoDispose<ContributionsAvailability>((ref) async {
  try {
    final features = await ref.watch(relativesApiProvider).features();
    return features.catalogContributionsEnabled
        ? ContributionsAvailability.available
        : ContributionsAvailability.disabled;
  } on ApiException catch (error) {
    return error.code == ApiException.networkError
        ? ContributionsAvailability.offline
        : ContributionsAvailability.unknown;
  }
});

/// A medication of the same profile with the composition of a chosen
/// product (D4).
@immutable
class SameMedication {
  /// Creates the match.
  const SameMedication({
    required this.id,
    required this.name,
    required this.consented,
  });

  /// Medication id.
  final String id;

  /// Its name, as the person typed it.
  final String name;

  /// Whether it already counts the chosen (GTIN, product) pair, so the
  /// prompt must not ask for consent again.
  final bool consented;
}

/// A product the person chose, with what the form needs to apply it.
@immutable
class CatalogPick {
  /// Creates a pick.
  const CatalogPick({
    required this.card,
    required this.link,
    required this.same,
  });

  /// The card as returned by the catalog or the cache (the composition is
  /// read from it: the card is not cached until a medication references it).
  final ProductCard card;

  /// The references to store.
  final CatalogLink link;

  /// Medications of the same profile with the same complete composition.
  final List<SameMedication> same;
}

/// Key of [catalogOverlapProvider].
@immutable
class OverlapQuery {
  /// Creates a query; [profileId] null is the own profile.
  OverlapQuery({
    required this.profileId,
    required this.excludeMedicationId,
    required Iterable<String> substanceIds,
  }) : substanceIds = (substanceIds.toSet().toList()..sort());

  /// The profile whose medications are compared.
  final String? profileId;

  /// The medication being edited (never compared with itself).
  final String? excludeMedicationId;

  /// Sorted catalog substance ids of the candidate.
  final List<String> substanceIds;

  @override
  bool operator ==(Object other) =>
      other is OverlapQuery &&
      other.profileId == profileId &&
      other.excludeMedicationId == excludeMedicationId &&
      listEquals(other.substanceIds, substanceIds);

  @override
  int get hashCode =>
      Object.hash(profileId, excludeMedicationId, Object.hashAll(substanceIds));
}

/// Substance ids a chosen product shares with other medications of the
/// profile; computed on the device from cached cards (ADR 0015 §6).
final catalogOverlapProvider =
    FutureProvider.autoDispose.family<Set<String>, OverlapQuery>(
  (ref, query) => ref.watch(catalogSelectionServiceProvider).overlap(query),
);

/// Opens cards and compares them with the medications of a profile.
final catalogSelectionServiceProvider = Provider<CatalogSelectionService>(
  CatalogSelectionService.new,
);

/// Turns a chosen search result into a [CatalogPick] and computes the
/// on-device hints; nothing leaves the phone except the card request.
class CatalogSelectionService {
  /// Creates the service.
  CatalogSelectionService(this._ref);

  final Ref<Object?> _ref;

  /// Opens the card of [productId] and finds the medications of [profileId]
  /// (null: own) with its composition, except [excludeMedicationId].
  /// Throws an [ApiException] when the card cannot be had.
  Future<CatalogPick> pick(
    String productId, {
    required String? profileId,
    String? excludeMedicationId,
  }) async {
    final cache = _ref.read(catalogCacheRepositoryProvider);
    final card = await cache.openCard(productId);
    if (card == null) {
      throw const ApiException(ApiException.networkError, 0);
    }
    final link = catalogLinkOf(card);
    final view = await _view(profileId);
    if (view == null) {
      return CatalogPick(card: card, link: link, same: const []);
    }
    final candidate = compositionCandidate(view.profileId, card);
    final ids = candidate == null
        ? const <String>[]
        : sameComposition(
            candidate,
            view.compositions,
            excludeMedicationId: excludeMedicationId,
          );
    return CatalogPick(
      card: card,
      link: link,
      same: [
        for (final id in ids)
          if (view.rows[id] case final row?)
            SameMedication(
              id: id,
              name: row.name ?? '',
              consented:
                  row.gtinLinkShared && CatalogLink.fromRow(row).samePair(link),
            ),
      ],
    );
  }

  /// The substance ids of [query] that other medications share.
  Future<Set<String>> overlap(OverlapQuery query) async {
    final view = await _view(query.profileId);
    if (view == null || query.substanceIds.isEmpty) {
      return const {};
    }
    final candidate = CompositionCandidate(
      profileId: view.profileId,
      compositionId: null,
      complete: false,
      substanceIds: query.substanceIds.toSet(),
    );
    return {
      for (final shared in substanceOverlap(
        candidate,
        view.compositions,
        excludeMedicationId: query.excludeMedicationId,
      ))
        ...shared.substanceIds,
    };
  }

  Future<_ProfileView?> _view(String? profileId) async {
    final id = profileId ?? (await _ref.read(selfProfileProvider.future))?.id;
    if (id == null) {
      return null;
    }
    final repository = _ref.read(medicationsRepositoryProvider);
    final rows = await repository.liveForProfile(id);
    final cards = await _ref.read(catalogCacheRepositoryProvider).cardsOf([
      for (final row in rows)
        if (row.catalogProductId case final product?) product,
    ]);
    return _ProfileView(
      profileId: id,
      rows: {for (final row in rows) row.id: row},
      compositions: medicationCompositions(rows, cards),
    );
  }
}

class _ProfileView {
  const _ProfileView({
    required this.profileId,
    required this.rows,
    required this.compositions,
  });

  final String profileId;
  final Map<String, MedicationRow> rows;
  final List<MedicationComposition> compositions;
}
