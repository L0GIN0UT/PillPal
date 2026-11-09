import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/catalog/catalog_dto.dart';
import 'package:pillpal/src/data/catalog/composition_inputs.dart';
import 'package:pillpal/src/data/catalog/manual_ingredient.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal_core/pillpal_core.dart';

import 'catalog_fixtures.dart';

// Local rows and cached cards feed the pure matching of pillpal_core
// (ADR 0015 §6); different profiles are never compared.

MedicationRow _row(
  String id, {
  String profileId = 'profile-a',
  String? productId,
  String? compositionId,
  String? manual,
  bool redacted = false,
  int? deletedAt,
}) {
  return MedicationRow(
    id: id,
    profileId: profileId,
    name: redacted ? null : id,
    tzMode: 'local',
    privacy: 'shared',
    redacted: redacted,
    catalogProductId: productId,
    catalogCompositionId: compositionId,
    manualIngredients: manual,
    gtinLinkShared: false,
    clientUpdatedAt: 1,
    updatedByDevice: 'd',
    deletedAt: deletedAt,
  );
}

ProductCard _card({
  String productId = productA,
  bool complete = true,
  List<String> substances = const [substanceX],
}) {
  final json = cardJson(
    productId: productId,
    complete: complete,
    substances: substances,
  );
  return ProductCard.fromJson(json);
}

void main() {
  final candidate = compositionCandidate('profile-a', _card())!;

  test('a cached card of the same complete composition is "same"', () {
    final rows = [_row('m1', productId: productA)];

    final meds = medicationCompositions(rows, {productA: _card()});

    expect(sameComposition(candidate, meds), ['m1']);
  });

  test('a composition the catalog marks incomplete is never "same"', () {
    final rows = [_row('m1', productId: productA)];
    final cards = {productA: _card(complete: false)};
    final partial = compositionCandidate('profile-a', _card(complete: false))!;

    final meds = medicationCompositions(rows, cards);

    expect(sameComposition(partial, meds), isEmpty);
    expect(sameComposition(candidate, meds), isEmpty);
  });

  test('a medication whose card is not cached is never "same"', () {
    final rows = [
      _row('m1', productId: productA, compositionId: compositionA),
    ];

    final meds = medicationCompositions(rows, const {});

    expect(sameComposition(candidate, meds), isEmpty);
  });

  test('catalog and manual substance ids drive the overlap hint', () {
    final manual = ManualIngredient.encode(const [
      ManualIngredient(name: 'Free', substanceId: substanceY),
    ]);
    final rows = [
      _row('m1', productId: productB),
      _row('m2', manual: manual),
    ];
    final cards = {
      productB: _card(productId: productB, substances: [substanceX]),
    };
    final both = compositionCandidate(
      'profile-a',
      _card(substances: [substanceX, substanceY]),
    )!;

    final overlap = substanceOverlap(
      both,
      medicationCompositions(rows, cards),
    );

    final byMedication = {
      for (final item in overlap) item.medicationId: item.substanceIds,
    };
    expect(byMedication, {
      'm1': {substanceX},
      'm2': {substanceY},
    });
  });

  test('free-text names never produce an overlap', () {
    final manual = ManualIngredient.encode(const [
      ManualIngredient(name: 'Substance'),
    ]);
    final rows = [_row('m1', manual: manual)];

    final meds = medicationCompositions(rows, const {});

    expect(substanceOverlap(candidate, meds), isEmpty);
  });

  test('another profile, deleted and redacted rows are ignored', () {
    final rows = [
      _row('other', productId: productA, profileId: 'profile-b'),
      _row('gone', productId: productA, deletedAt: 5),
      _row('hidden', productId: productA, redacted: true),
    ];
    final cards = {productA: _card()};

    final meds = medicationCompositions(rows, cards);

    expect(sameComposition(candidate, meds), isEmpty);
    expect(substanceOverlap(candidate, meds), isEmpty);
  });

  test('a product without a composition has no candidate', () {
    final card = ProductCard.fromJson(cardJson(compositionId: null));

    expect(compositionCandidate('profile-a', card), isNull);
  });
}
