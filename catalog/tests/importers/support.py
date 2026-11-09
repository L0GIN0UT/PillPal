"""Shared constants and helpers of the catalog data tests."""

from __future__ import annotations

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

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


async def wipe_catalog(engine: AsyncEngine) -> None:
    async with engine.begin() as conn:
        for table in CONTENT_TABLES:
            await conn.execute(text(f"DELETE FROM catalog.{table}"))  # noqa: S608
        await conn.execute(
            text("DELETE FROM catalog.sources WHERE code <> ALL(:seeded)"),
            {"seeded": list(SEEDED_SOURCES)},
        )
