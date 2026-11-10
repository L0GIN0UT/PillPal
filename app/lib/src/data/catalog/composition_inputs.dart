import 'package:pillpal_core/pillpal_core.dart';

import '../db/database.dart';
import '../repositories/local_writer.dart';
import 'catalog_dto.dart';
import 'manual_ingredient.dart';

// The bridge between local rows / cached cards and the pure matching of
// `pillpal_core` (ADR 0015 §6). Everything stays on the device.

/// The matching view of the live, unredacted [rows] of one or more
/// profiles. [cards] are the cached cards by product id: a medication
/// whose card is not cached has an unknown, hence never "same", composition
/// but keeps its manual substance ids.
List<MedicationComposition> medicationCompositions(
  Iterable<MedicationRow> rows,
  Map<String, ProductCard> cards,
) {
  final result = <MedicationComposition>[];
  for (final row in rows) {
    if (row.deletedAt != null || row.redacted) {
      continue;
    }
    final productId = row.catalogProductId;
    final card = productId == null ? null : cards[productId];
    final composition = card?.composition;
    result.add(
      MedicationComposition(
        medicationId: row.id,
        profileId: row.profileId,
        compositionId: composition?.id ?? row.catalogCompositionId,
        complete: composition?.complete ?? false,
        catalogSubstanceIds: _substanceIds(composition),
        manualSubstanceIds: _manualSubstanceIds(row),
      ),
    );
  }
  return result;
}

/// The matching view of the product whose [card] the user is about to link
/// to a medication of [profileId]; null when the product has no
/// composition.
CompositionCandidate? compositionCandidate(
  String profileId,
  ProductCard card,
) {
  final composition = card.composition;
  if (composition == null) {
    return null;
  }
  return CompositionCandidate(
    profileId: profileId,
    compositionId: composition.id,
    complete: composition.complete,
    substanceIds: _substanceIds(composition),
  );
}

Set<String> _substanceIds(CompositionOut? composition) {
  if (composition == null) {
    return const {};
  }
  return {for (final line in composition.ingredients) line.substanceId};
}

Set<String> _manualSubstanceIds(MedicationRow row) {
  final ids = <String>{};
  final List<ManualIngredient> lines;
  try {
    lines = ManualIngredient.decode(row.manualIngredients);
  } on DataException {
    return ids; // a corrupt stored composition never produces a hint
  }
  for (final line in lines) {
    final id = line.substanceId;
    if (id != null) {
      ids.add(id);
    }
  }
  return ids;
}
