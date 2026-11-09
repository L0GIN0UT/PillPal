"""Synthetic data in the shape of EMA's "Medicines output" workbook (privacy rule 9): invented
medicine names, product numbers, substances and holders. FORMAT STATUS: synthetic only; the
real file's wording and layout (a few title rows above the header) are unverified."""

from __future__ import annotations

from collections.abc import Sequence
from pathlib import Path

from tests.importers.xlsx_support import Cell, build_xlsx

SHEET = "Medicines"
INTRO: list[list[Cell]] = [
    ["Medicines output: European public assessment reports (synthetic)"],
    ["Report generated on 2026-10-01"],
    [],
]
HEADER: list[Cell] = [
    "Category",
    "Medicine name",
    "Therapeutic area",
    "Active substance",
    "Product number",
    "Authorisation status",
    "ATC code",
    "Marketing authorisation holder/company name",
    "URL",
]
HOLDER = "Testpharma Europe B.V."
NUMBER = 4  # column of the product number in a row


def row(
    name: str,
    substance: str,
    number: str,
    *,
    category: str = "Human",
    status: str = "Authorised",
    holder: str | None = HOLDER,
) -> list[Cell]:
    return [category, name, "Testing", substance, number, status, "N00AA00", holder, None]


ROWS: list[list[Cell]] = [
    row("Testamolex", "testamol", "EMEA/H/C/900001"),
    row("Duoprobin", "testamol, probinol", "EMEA/H/C/900002", holder="Probin Holdings GmbH"),
    row("Testamol Generic", "Testamol", "EMEA/H/C/900003"),
    row("Withdrawnex", "ramolin", "EMEA/H/C/900004", status="Withdrawn"),
    row("Refusedex", "ramolin", "EMEA/H/C/900005", status="Refused", holder=None),
    row("Vetotestam", "testamol", "EMEA/V/C/900006", category="Veterinary"),
    row("Triplex", "alfanol; betanol / gammanol", "EMEA/H/C/900007"),
]


def workbook(
    path: Path, rows: Sequence[Sequence[Cell]] = ROWS, *, intro: bool = True, **options: object
) -> Path:
    sheet = [*(INTRO if intro else []), HEADER, *rows]
    return build_xlsx(path, {SHEET: sheet}, **options)  # type: ignore[arg-type]


def snapshot(folder: Path, rows: Sequence[Sequence[Cell]] = ROWS) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    workbook(folder / "ema.xlsx", rows)
    return folder
