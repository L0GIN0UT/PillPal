"""Cleaning shared by the Russian source importers (ESKLP, Roszdravnadzor, GRLS export).

Everything here is pure and defensive: a value that does not fit is dropped (``None``) so the
importer can count it, and no function ever puts the input into an exception message. Only the
fields the catalog needs are ever read from a source, so personal details that sources may print
next to a manufacturer (an individual entrepreneur's address, for instance) never get this far.
"""

from __future__ import annotations

import re
from collections import Counter

from catalog.domain.gtin import GtinError, normalize
from catalog.importers.strength import Strength, parse_strength

MAX_BARCODES_PER_PACKAGE = 5
MAX_REGISTRATION_NUMBER_CHARS = 64
_SEPARATORS = re.compile(r"[;,/\s]+")
_DASHES = re.compile("[\u2010-\u2015\u2212]")
_SPACES_AROUND_DASH = re.compile(r"\s*-\s*")
_DECIMAL_COMMA = re.compile(r"(?<=\d),(?=\d)")
_PLUS = re.compile(r"\s*\+\s*")


def clean_text(value: object, limit: int) -> str | None:
    """Printable text with single spaces, or ``None`` when empty, too long or malformed."""
    if not isinstance(value, str):
        return None
    text = " ".join(value.split())  # also folds no-break spaces and newlines
    if not 0 < len(text) <= limit or "\x00" in text:
        return None
    try:
        text.encode("utf-8")  # a lone surrogate can be neither stored nor logged
    except UnicodeEncodeError:
        return None
    return text


def name_key(text: str) -> str:
    """The comparison form of a name: case folded, ``ё`` as ``е``, single spaces."""
    return " ".join(text.casefold().replace("ё", "е").split())


def normalize_registration_number(value: object) -> str | None:
    """The registration certificate number in one shape, so sources can be joined on it."""
    text = clean_text(value, MAX_REGISTRATION_NUMBER_CHARS)
    if text is None:
        return None
    return _SPACES_AROUND_DASH.sub("-", _DASHES.sub("-", text)).upper()


def parse_barcodes(raw: object, skipped: Counter[str]) -> tuple[str, ...]:
    """GTIN-14 of every shareable barcode in ``raw``; the rest is counted, never listed.

    Sources print one or several EAN/GTIN values separated by ``;`` or ``,``. Restricted
    circulation numbers (docs/spec/gtin.md section 3) and values with a bad check digit are
    skipped.
    """
    if not isinstance(raw, str) or not raw.strip():
        return ()
    found: dict[str, None] = {}
    for candidate in (p for p in _SEPARATORS.split(raw.strip()) if p):
        if len(found) >= MAX_BARCODES_PER_PACKAGE:
            skipped["gtin_too_many"] += 1
            break
        try:
            gtin = normalize(candidate)
        except GtinError:
            skipped["gtin_invalid"] += 1
            continue
        if gtin.classification == "restricted":
            skipped["gtin_restricted"] += 1
            continue
        found[gtin.gtin14] = None
    return tuple(found)


def inn_parts(text: str) -> list[str]:
    """The ingredient names of a combination INN (``A + B``)."""
    return [part for part in (clean_text(p, 200) for p in _PLUS.split(text)) if part]


def parse_dosages(text: str | None, ingredients: int) -> list[Strength | None]:
    """One strength per ingredient, or ``None`` for each when the text does not line up.

    ``250 мг+125 мг`` is two strengths for a two-ingredient INN; a count mismatch (a dosage
    printed for a different shape of the INN) makes every strength unknown rather than guessed.
    Russian decimals use a comma.
    """
    unknown: list[Strength | None] = [None] * ingredients
    if not text:
        return unknown
    parts = _PLUS.split(" ".join(_DECIMAL_COMMA.sub(".", text).split()))
    if len(parts) != ingredients:
        return unknown
    parsed = [parse_strength(part) for part in parts]
    return parsed if all(p is not None for p in parsed) else unknown
