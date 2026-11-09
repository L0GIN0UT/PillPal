"""SMNN rows (INN + dosage form + strength) as ESKLP prints them -> catalog substances and
compositions. Pure; counts what it drops in ``skipped`` and never guesses:

- a substance is source-local (``inn:<folded name>``): ESKLP prints Russian INNs and no UNII, so
  nothing links it to RxNorm unless a row carries an explicit ``rxcui`` (single-ingredient SMNN
  only, and one rxcui per INN for the whole file, the first one seen);
- a composition is ``complete`` only when the form is known and every ingredient has a parsed
  strength; a dosage that does not line up with the INN leaves every strength unknown;
- two SMNN with the same form and ingredients are one composition (the first key is kept).
"""

from __future__ import annotations

import re
import uuid
from collections import Counter
from collections.abc import Iterator, Mapping
from dataclasses import dataclass

from catalog.domain.identity import IngredientKey, composition_identity_key
from catalog.importers.base import (
    CompositionRecord,
    IngredientRecord,
    SubstanceRecord,
)
from catalog.importers.ids import substance_id
from catalog.importers.ru_common import (
    ESKLP_SOURCE,
    MARKET,
    clean_text,
    inn_parts,
    name_key,
    parse_dosages,
)

MAX_NAME_CHARS = 200
RXNORM_SOURCE = "rxnorm"
_RXCUI = re.compile(r"\d{1,12}", re.ASCII)


def canonical_uuid(value: str | None) -> str | None:
    """Lower-case canonical form of a UUID, or ``None``; keys must not depend on spelling."""
    if not value:
        return None
    try:
        return str(uuid.UUID(value.strip()))
    except ValueError:
        return None


@dataclass(frozen=True)
class _Smnn:
    key: str
    names: tuple[str, ...]
    form: str | None
    dosage: str | None
    rxcui: str | None


class SmnnCatalog:
    """Collects SMNN rows (``add``), then yields substances and compositions in load order."""

    def __init__(self, skipped: Counter[str]) -> None:
        self._skipped = skipped
        self._rows: dict[str, _Smnn] = {}
        self._rxcui_of_inn: dict[str, str] = {}
        self.composition_of: dict[str, str] = {}  # smnn key -> key of the kept composition

    def add(self, row: Mapping[str, str | None]) -> None:
        if not row.get("smnn_uuid"):
            return  # a trade item without a SMNN reference
        key = canonical_uuid(row.get("smnn_uuid"))
        if key is None:
            self._skipped["invalid_smnn"] += 1
            return
        inn = clean_text(row.get("inn"), MAX_NAME_CHARS * 2)
        if inn is None:
            return  # a reference only (the trade-item sheet of a two-sheet file)
        if key in self._rows:
            return  # a flat sheet repeats its SMNN on every trade item
        names = tuple(inn_parts(inn))
        if not names:
            self._skipped["invalid_smnn"] += 1
            return
        rxcui = clean_text(row.get("rxcui"), 12)
        rxcui = rxcui if rxcui and _RXCUI.fullmatch(rxcui) and len(names) == 1 else None
        if rxcui:
            self._rxcui_of_inn.setdefault(name_key(names[0]), rxcui)
        self._rows[key] = _Smnn(
            key=key,
            names=names,
            form=clean_text(row.get("form"), MAX_NAME_CHARS),
            dosage=clean_text(row.get("dosage"), MAX_NAME_CHARS),
            rxcui=rxcui,
        )

    def substances(self) -> Iterator[SubstanceRecord]:
        names: dict[str, str] = {}
        for row in self._rows.values():
            for name in row.names:
                names.setdefault(f"inn:{name_key(name)}", name)
        for key in sorted(names):
            yield SubstanceRecord(source_key=key, market=MARKET, name_ru=names[key])

    def compositions(self) -> Iterator[CompositionRecord]:
        seen: dict[str, str] = {}
        for key in sorted(self._rows):
            record = self._composition(self._rows[key])
            identity = composition_identity_key(
                record.form_code,
                [
                    IngredientKey(
                        substance_id(ESKLP_SOURCE, i.substance_key),
                        i.strength_value,
                        i.strength_unit,
                        i.per_value,
                        i.per_unit,
                    )
                    for i in record.ingredients
                ],
            )
            if identity in seen:
                self._skipped["duplicate_composition"] += 1
                self.composition_of[key] = seen[identity]
                continue
            seen[identity] = key
            self.composition_of[key] = key
            yield record

    def _composition(self, row: _Smnn) -> CompositionRecord:
        strengths = parse_dosages(row.dosage, len(row.names))
        ingredients = tuple(
            IngredientRecord(
                substance_key=f"inn:{name_key(name)}",
                strength_value=strength.value if strength else None,
                strength_unit=strength.unit if strength else None,
                per_value=strength.per_value if strength else None,
                per_unit=strength.per_unit if strength else None,
                shared_substance=self._shared(name, row),
            )
            for name, strength in zip(row.names, strengths, strict=True)
        )
        form_code = f"form:{name_key(row.form)}" if row.form else None
        return CompositionRecord(
            source_key=row.key,
            market=MARKET,
            form_code=form_code,
            form_name_ru=row.form,
            ingredients=ingredients,
            complete=form_code is not None
            and all(i.strength_value is not None for i in ingredients),
        )

    def _shared(self, name: str, row: _Smnn) -> tuple[str, str] | None:
        if len(row.names) != 1:
            return None
        rxcui = self._rxcui_of_inn.get(name_key(name))
        return (RXNORM_SOURCE, rxcui) if rxcui else None
