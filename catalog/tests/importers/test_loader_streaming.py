"""The loader consumes records incrementally (bounded memory) and resolves a product's composition
from an ordered list of candidates. Real PostgreSQL; the importer is an in-test generator."""

from __future__ import annotations

from collections.abc import Callable, Iterator
from decimal import Decimal
from pathlib import Path
from typing import Any

import pytest
import pytest_asyncio
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from catalog.importers import loader
from catalog.importers.base import (
    CompositionRecord,
    ImporterDataError,
    IngredientRecord,
    LicenseNote,
    ProductRecord,
    Record,
    SnapshotManifest,
    SubstanceRecord,
)
from catalog.importers.fixture import ensure_dev_source
from catalog.importers.loader import run_import
from tests.importers.support import rows

Sessions = async_sessionmaker[AsyncSession]
SOURCE = "stream_test"
OTHER = "stream_other"
BATCH = 3


class GeneratorImporter:
    """Parses by calling ``make``; ``skipped`` mimics an importer that dropped records."""

    license = LicenseNote("test", "test", "test", "https://pillpal.invalid/test")

    def __init__(
        self,
        make: Callable[[], Iterator[Record]],
        source: str = SOURCE,
        skipped: dict[str, int] | None = None,
    ) -> None:
        self.source = source
        self._make = make
        self.skipped: dict[str, int] = skipped or {}

    def ensure_enabled(self) -> None:
        return None

    def fetch(self, dest: Path) -> SnapshotManifest:
        raise NotImplementedError

    def snapshot_version(self, snapshot_dir: Path) -> str | None:
        return None

    def parse(self, snapshot_dir: Path) -> Iterator[Record]:
        return self._make()


@pytest_asyncio.fixture(autouse=True)
async def dev_sources(sessionmaker: Sessions) -> None:
    async with sessionmaker.begin() as session:
        for code in (SOURCE, OTHER):
            await ensure_dev_source(session, code)


def _substance(i: int) -> SubstanceRecord:
    return SubstanceRecord(source_key=f"S{i}", market="us", name_en=f"Teststuff {i}")


def _composition(i: int) -> CompositionRecord:
    ingredient = IngredientRecord(f"S{i}", Decimal(100 + i), "mg")
    return CompositionRecord(f"C{i}", "us", "tab", (ingredient,), complete=True)


def _product(i: int, **extra: Any) -> ProductRecord:
    return ProductRecord(source_key=f"P{i}", market="us", brand_name=f"Testbrand {i}", **extra)


def _chain(count: int) -> Iterator[Record]:
    for i in range(count):
        yield _substance(i)
    for i in range(count):
        yield _composition(i)
    for i in range(count):
        yield _product(i, composition_key=f"C{i}")


async def test_small_batches_load_every_record_and_resolve_links(
    sessionmaker: Sessions, engine: AsyncEngine, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(loader, "RECORD_BATCH_SIZE", BATCH)

    result = await run_import(sessionmaker, GeneratorImporter(lambda: _chain(11)), tmp_path)

    assert result.counts["substances"]["inserted"] == 11
    assert result.counts["compositions"]["inserted"] == 11
    assert result.counts["products"]["inserted"] == 11
    assert result.counts["search_entities_rebuilt"] == 22
    links = await rows(
        engine,
        "SELECT count(*) FROM catalog.products p JOIN catalog.compositions c "
        "ON c.id = p.composition_id AND right(c.source_key, -1) = right(p.source_key, -1)",
    )
    assert links[0][0] == 11
    ingredients = await rows(engine, "SELECT count(*) FROM catalog.composition_ingredients")
    assert ingredients[0][0] == 11
    entries = await rows(engine, "SELECT count(*) FROM catalog.search_entries")
    assert entries[0][0] == 22


async def test_the_parser_is_consumed_lazily(
    sessionmaker: Sessions, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(loader, "RECORD_BATCH_SIZE", BATCH)
    produced = 0

    def make() -> Iterator[Record]:
        nonlocal produced
        for record in _chain(10):
            produced += 1
            yield record

    seen_at_write: list[int] = []
    original = loader.load_substances

    async def spy(*args: Any, **kwargs: Any) -> Any:
        seen_at_write.append(produced)
        return await original(*args, **kwargs)

    monkeypatch.setattr(loader, "load_substances", spy)

    await run_import(sessionmaker, GeneratorImporter(make), tmp_path)

    assert produced == 30
    # The first write happens when only the first batch (plus one peeked record) was parsed.
    assert seen_at_write[0] <= BATCH + 1
    assert len(seen_at_write) == 4


async def test_a_failure_after_some_batches_rolls_everything_back(
    sessionmaker: Sessions, engine: AsyncEngine, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(loader, "RECORD_BATCH_SIZE", BATCH)

    def make() -> Iterator[Record]:
        yield from (_substance(i) for i in range(7))
        raise ImporterDataError("invalid_snapshot")

    with pytest.raises(ImporterDataError):
        await run_import(sessionmaker, GeneratorImporter(make), tmp_path)

    for table in ("substances", "search_entries", "substance_names"):
        assert (await rows(engine, f"SELECT count(*) FROM catalog.{table}"))[0][0] == 0  # noqa: S608
    run = (await rows(engine, "SELECT status, error_code FROM catalog.import_runs"))[0]
    assert tuple(run) == ("failed", "invalid_snapshot")


async def test_records_must_come_substances_then_compositions_then_products(
    sessionmaker: Sessions, tmp_path: Path
) -> None:
    def make() -> Iterator[Record]:
        yield _substance(1)
        yield _product(1)
        yield _composition(1)

    with pytest.raises(ImporterDataError) as caught:
        await run_import(sessionmaker, GeneratorImporter(make), tmp_path)
    assert caught.value.code == "records_out_of_order"


async def test_a_product_links_to_the_first_candidate_composition_that_exists(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    def other() -> Iterator[Record]:
        yield _substance(1)
        yield _composition(1)

    await run_import(sessionmaker, GeneratorImporter(other, source=OTHER), tmp_path)

    def make() -> Iterator[Record]:
        yield _substance(2)
        yield _composition(2)
        yield _product(
            1,
            composition_source=OTHER,
            composition_key="C-MISSING",
            composition_alternatives=((OTHER, "C1"), (SOURCE, "C2")),
        )
        yield _product(2, composition_source=OTHER, composition_key="C-MISSING")
        yield _product(
            3,
            composition_source=OTHER,
            composition_key="C-MISSING",
            composition_alternatives=((SOURCE, "C2"),),
        )
        yield _product(
            4,
            composition_key="C-NOPE",
            composition_alternatives=((OTHER, "C-NOPE-TOO"),),
        )

    result = await run_import(sessionmaker, GeneratorImporter(make), tmp_path)

    found = await rows(
        engine,
        "SELECT p.source_key, c.source, c.source_key FROM catalog.products p "
        "LEFT JOIN catalog.compositions c ON c.id = p.composition_id "
        "WHERE p.source = :s ORDER BY p.source_key",
        s=SOURCE,
    )
    assert [tuple(r) for r in found] == [
        ("P1", OTHER, "C1"),  # the first candidate that exists wins
        ("P2", None, None),
        ("P3", SOURCE, "C2"),  # falls through to the product's own composition
        ("P4", None, None),
    ]
    assert result.counts["products_unlinked"] == 2


async def test_skipped_records_reported_by_the_importer_land_in_the_run_counts(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    importer = GeneratorImporter(lambda: iter([_substance(1)]), skipped={"not_finished": 4})

    await run_import(sessionmaker, importer, tmp_path)

    counts = (await rows(engine, "SELECT counts FROM catalog.import_runs"))[0][0]
    assert counts["parse_skipped"] == {"not_finished": 4}


async def test_no_skips_adds_no_key(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    await run_import(sessionmaker, GeneratorImporter(lambda: iter([_substance(1)])), tmp_path)

    counts = (await rows(engine, "SELECT counts FROM catalog.import_runs"))[0][0]
    assert "parse_skipped" not in counts


async def test_the_parser_generator_is_closed_when_the_load_stops_early(
    sessionmaker: Sessions, tmp_path: Path
) -> None:
    closed = False

    def make() -> Iterator[Record]:
        nonlocal closed
        try:
            yield _substance(1)
            yield _product(1)
            yield _composition(1)  # out of order: the loader refuses here
            yield _composition(2)
        finally:
            closed = True

    with pytest.raises(ImporterDataError):
        await run_import(sessionmaker, GeneratorImporter(make), tmp_path)

    assert closed is True
