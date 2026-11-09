"""The parts of the RxNorm Prescribable RRF files the importer needs, read in one pass per file.

Only RXNORM-vocabulary atoms that are English and not suppressed are kept, and only the term types
ingredient (IN), precise ingredient (PIN), semantic clinical drug (SCD), its component (SCDC) and
dose form (DF). Relations are oriented by the term types of their two ends, because RxNorm stores
every relation in both directions. Memory is proportional to the number of kept concepts, not to
the size of the files.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

from catalog.importers.rrf import iter_rrf

RXNORM_VOCABULARY = "RXNORM"
NOT_SUPPRESSED = "N"
ENGLISH = "ENG"
PREFERRED = "Y"
KEPT_TERM_TYPES = frozenset({"IN", "PIN", "SCD", "SCDC", "DF"})
BOSS_NUM_VALUE = "RXN_BOSS_STRENGTH_NUM_VALUE"
BOSS_NUM_UNIT = "RXN_BOSS_STRENGTH_NUM_UNIT"
BOSS_DENOM_VALUE = "RXN_BOSS_STRENGTH_DENOM_VALUE"
BOSS_DENOM_UNIT = "RXN_BOSS_STRENGTH_DENOM_UNIT"
AVAILABLE_STRENGTH = "RXN_AVAILABLE_STRENGTH"
STRENGTH_ATTRIBUTES = frozenset(
    {BOSS_NUM_VALUE, BOSS_NUM_UNIT, BOSS_DENOM_VALUE, BOSS_DENOM_UNIT, AVAILABLE_STRENGTH}
)

# RXNCONSO / RXNREL / RXNSAT column positions (UMLS Reference Manual).
CONSO_RXCUI = 0
CONSO_LAT = 1
CONSO_ISPREF = 6
CONSO_SAB = 11
CONSO_TTY = 12
CONSO_STR = 14
CONSO_SUPPRESS = 16
CONSO_FIELDS = CONSO_SUPPRESS + 1
REL_RXCUI1 = 0
REL_RXCUI2 = 4
REL_RELA = 7
REL_SAB = 10
REL_SUPPRESS = 14
REL_FIELDS = REL_SUPPRESS + 1
SAT_RXCUI = 0
SAT_ATN = 8
SAT_SAB = 9
SAT_ATV = 10
SAT_SUPPRESS = 11
SAT_FIELDS = SAT_SUPPRESS + 1

# (relation names, owner term type, member term type, index attribute)
_LINKS = (
    (frozenset({"consists_of", "constitutes"}), "SCD", "SCDC", "components"),
    (frozenset({"has_ingredient", "ingredient_of"}), "SCDC", "IN", "ingredients"),
    (frozenset({"has_precise_ingredient", "precise_ingredient_of"}), "SCDC", "PIN", "precise"),
    (frozenset({"has_dose_form", "dose_form_of"}), "SCD", "DF", "dose_forms"),
)


@dataclass
class RxNormIndex:
    concepts: dict[str, tuple[str, str]] = field(default_factory=dict)  # rxcui -> (tty, name)
    components: dict[str, set[str]] = field(default_factory=lambda: defaultdict(set))
    ingredients: dict[str, set[str]] = field(default_factory=lambda: defaultdict(set))
    precise: dict[str, set[str]] = field(default_factory=lambda: defaultdict(set))
    dose_forms: dict[str, set[str]] = field(default_factory=lambda: defaultdict(set))
    attributes: dict[str, dict[str, str]] = field(default_factory=lambda: defaultdict(dict))

    def of_type(self, *term_types: str) -> list[str]:
        found = [rxcui for rxcui, (tty, _) in self.concepts.items() if tty in term_types]
        return sorted(found, key=rxcui_order)


def rxcui_order(rxcui: str) -> tuple[int, str]:
    """Numeric order for digit strings, so output order does not depend on the file."""
    return (len(rxcui), rxcui)


def _usable(sab: str, suppress: str) -> bool:
    return sab == RXNORM_VOCABULARY and suppress == NOT_SUPPRESSED


def read_concepts(path: Path, index: RxNormIndex) -> None:
    preferred: set[str] = set()
    for row in iter_rrf(path, CONSO_FIELDS):
        tty = row[CONSO_TTY]
        if not _usable(row[CONSO_SAB], row[CONSO_SUPPRESS]) or tty not in KEPT_TERM_TYPES:
            continue
        rxcui = row[CONSO_RXCUI]
        if row[CONSO_LAT] != ENGLISH or not row[CONSO_STR].strip():
            continue
        is_preferred = row[CONSO_ISPREF] == PREFERRED
        if rxcui not in index.concepts or (is_preferred and rxcui not in preferred):
            index.concepts[rxcui] = (tty, row[CONSO_STR].strip())
        if is_preferred:
            preferred.add(rxcui)


def read_relations(path: Path, index: RxNormIndex) -> None:
    for row in iter_rrf(path, REL_FIELDS):
        if not _usable(row[REL_SAB], row[REL_SUPPRESS]):
            continue
        first, second = row[REL_RXCUI1], row[REL_RXCUI2]
        if first not in index.concepts or second not in index.concepts:
            continue
        ends = (index.concepts[first][0], index.concepts[second][0])
        for relas, owner, member, attribute in _LINKS:
            if row[REL_RELA] not in relas:
                continue
            target: dict[str, set[str]] = getattr(index, attribute)
            if ends == (owner, member):
                target[first].add(second)
            elif ends == (member, owner):
                target[second].add(first)


def read_attributes(path: Path, index: RxNormIndex) -> None:
    for row in iter_rrf(path, SAT_FIELDS):
        if not _usable(row[SAT_SAB], row[SAT_SUPPRESS]) or row[SAT_ATN] not in STRENGTH_ATTRIBUTES:
            continue
        rxcui = row[SAT_RXCUI]
        if rxcui in index.concepts:
            index.attributes[rxcui].setdefault(row[SAT_ATN], row[SAT_ATV].strip())
