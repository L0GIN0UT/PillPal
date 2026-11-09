"""Column lookup for spreadsheet and CSV exports whose header wording is not under our control.

A header is compared in a folded form (case, ``ё``, spaces and punctuation ignored), so ``Номер
РУ``, ``номер ру`` and ``Номер_РУ`` are one name. A column is found by any of its aliases; a file
without a required column is refused (``missing_columns``) instead of read with a guess.
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Mapping, Sequence

from catalog.importers.base import ImporterDataError

_NOT_WORD = re.compile(r"[\W_]+")


def header_key(text: str) -> str:
    return _NOT_WORD.sub("", text.casefold().replace("ё", "е"))


def fold_aliases(aliases: Mapping[str, Iterable[str]]) -> dict[str, frozenset[str]]:
    return {field: frozenset(header_key(a) for a in names) for field, names in aliases.items()}


def find_columns(
    header: Sequence[str | None], aliases: Mapping[str, frozenset[str]]
) -> dict[str, int]:
    """Position of every field whose alias occurs in ``header`` (the first one wins)."""
    found: dict[str, int] = {}
    for position, cell in enumerate(header):
        if cell is None:
            continue
        key = header_key(cell)
        for field, names in aliases.items():
            if field not in found and key in names:
                found[field] = position
    return found


def require_columns(columns: Mapping[str, int], required: Iterable[str]) -> None:
    if any(field not in columns for field in required):
        raise ImporterDataError("missing_columns")


def cell(row: Sequence[str | None], columns: Mapping[str, int], field: str) -> str | None:
    position = columns.get(field)
    if position is None or position >= len(row):
        return None
    return row[position]
