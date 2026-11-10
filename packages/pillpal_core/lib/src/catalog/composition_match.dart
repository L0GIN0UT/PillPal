// On-device matching of catalog compositions (ADR 0015 section 6). Pure and
// local: nothing here talks to a server. There is deliberately no analog
// list (owner decision D9): only "same composition" and "both contain".

/// The composition of the product the user is about to link.
class CompositionCandidate {
  /// Creates a candidate for [profileId].
  const CompositionCandidate({
    required this.profileId,
    required this.compositionId,
    required this.complete,
    required this.substanceIds,
  });

  /// Profile the new link belongs to; only its medications are compared.
  final String profileId;

  /// Catalog composition row, null when the product has none.
  final String? compositionId;

  /// Whether the catalog marks the composition complete (ADR 0012 section 1).
  final bool complete;

  /// Catalog substance ids of the composition.
  final Set<String> substanceIds;
}

/// A live medication of a profile with what is known about its composition.
class MedicationComposition {
  /// Creates the composition view of medication [medicationId].
  const MedicationComposition({
    required this.medicationId,
    required this.profileId,
    required this.compositionId,
    required this.complete,
    required this.catalogSubstanceIds,
    this.manualSubstanceIds = const {},
  });

  /// The medication.
  final String medicationId;

  /// Its profile.
  final String profileId;

  /// Linked catalog composition, null when unlinked or not cached.
  final String? compositionId;

  /// Whether that composition is complete.
  final bool complete;

  /// Substance ids of the linked composition (from the cached card).
  final Set<String> catalogSubstanceIds;

  /// Substance ids picked from the catalog in the private manual
  /// composition. Free-text names are never used for matching.
  final Set<String> manualSubstanceIds;

  /// Catalog and manual substance ids together.
  Set<String> get allSubstanceIds {
    return {...catalogSubstanceIds, ...manualSubstanceIds};
  }
}

/// Shared substances between the candidate and one medication.
class SubstanceOverlap {
  /// Creates an overlap of [substanceIds] with [medicationId].
  const SubstanceOverlap({
    required this.medicationId,
    required this.substanceIds,
  });

  /// The medication that shares the substances.
  final String medicationId;

  /// The shared catalog substance ids (never empty).
  final Set<String> substanceIds;
}

/// Ids of medications in the candidate's profile whose composition is the
/// candidate's: the same composition row, and complete on both sides. An
/// incomplete composition never counts as the same.
List<String> sameComposition(
  CompositionCandidate candidate,
  Iterable<MedicationComposition> medications, {
  String? excludeMedicationId,
}) {
  final compositionId = candidate.compositionId;
  if (compositionId == null || !candidate.complete) {
    return const [];
  }
  final result = <String>[];
  for (final med in medications) {
    if (!_comparable(candidate, med, excludeMedicationId)) {
      continue;
    }
    if (med.complete && med.compositionId == compositionId) {
      result.add(med.medicationId);
    }
  }
  return result;
}

/// Medications in the candidate's profile that share at least one catalog
/// substance id with the candidate (manual substance ids included).
List<SubstanceOverlap> substanceOverlap(
  CompositionCandidate candidate,
  Iterable<MedicationComposition> medications, {
  String? excludeMedicationId,
}) {
  final result = <SubstanceOverlap>[];
  for (final med in medications) {
    if (!_comparable(candidate, med, excludeMedicationId)) {
      continue;
    }
    final shared = candidate.substanceIds.intersection(med.allSubstanceIds);
    if (shared.isNotEmpty) {
      result.add(
        SubstanceOverlap(medicationId: med.medicationId, substanceIds: shared),
      );
    }
  }
  return result;
}

/// Only medications of the candidate's profile are compared, and never the
/// medication being edited against itself.
bool _comparable(
  CompositionCandidate candidate,
  MedicationComposition med,
  String? excludeMedicationId,
) {
  return med.profileId == candidate.profileId &&
      med.medicationId != excludeMedicationId;
}
