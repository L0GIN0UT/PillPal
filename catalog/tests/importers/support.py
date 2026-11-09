"""Shared constants and helpers of the catalog data tests."""

from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path
from typing import Any

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import CATALOG_DIR

SEEDED_SOURCES = (
    "rxnorm",
    "openfda_ndc",
    "ema",
    "esklp",
    "ru_roszdravnadzor",
    "grls_manual",
    "wikidata",
    "consensus",
)
CONTENT_TABLES = (
    "search_entries",
    "recall_flags",
    "gtins",
    "packages",
    "products",
    "composition_ingredients",
    "compositions",
    "substance_names",
    "substances",
    "import_runs",
)
# Sources the c0002 seed enables; a run of a gated source enables its row (restored on wipe).
SEED_ENABLED = ("rxnorm", "openfda_ndc", "consensus")
# Tables an import must leave identical when it has nothing to change (or when it fails).
DATA_TABLES = tuple(t for t in CONTENT_TABLES if t != "import_runs")
FIXTURES = CATALOG_DIR / "tests" / "fixtures" / "fixture"
V1, V2 = FIXTURES / "v1", FIXTURES / "v2"


async def wipe_catalog(engine: AsyncEngine) -> None:
    async with engine.begin() as conn:
        for table in CONTENT_TABLES:
            await conn.execute(text(f"DELETE FROM catalog.{table}"))  # noqa: S608
        await conn.execute(
            text("UPDATE catalog.sources SET enabled = (code = ANY(:enabled))"),
            {"enabled": list(SEED_ENABLED)},
        )
        await conn.execute(
            text("DELETE FROM catalog.sources WHERE code <> ALL(:seeded)"),
            {"seeded": list(SEEDED_SOURCES)},
        )


async def dump(engine: AsyncEngine, tables: tuple[str, ...] = DATA_TABLES) -> dict[str, Any]:
    """Every row of the given tables in a stable order, for before/after comparisons."""
    out: dict[str, Any] = {}
    async with engine.connect() as conn:
        for table in tables:
            found = (await conn.execute(text(f"SELECT * FROM catalog.{table}"))).all()  # noqa: S608
            out[table] = sorted(repr(tuple(r)) for r in found)
    return out


async def rows(engine: AsyncEngine, sql: str, **params: object) -> list[Any]:
    async with engine.connect() as conn:
        return list((await conn.execute(text(sql), params)).all())


def mutated_snapshot(
    tmp_path: Path, mutate: Callable[[dict[str, Any]], None], base: Path = V1, name: str = "snap"
) -> Path:
    """A copy of a fixture snapshot with ``mutate`` applied to its data."""
    dest = tmp_path / name
    dest.mkdir(parents=True)
    data = json.loads((base / "data.json").read_text(encoding="utf-8"))
    mutate(data)
    (dest / "data.json").write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    return dest
