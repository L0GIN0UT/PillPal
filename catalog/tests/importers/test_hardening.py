"""Review follow-ups of 4.3: cross-source links, runs that never stay running, stale takeover,
error messages without values, scoped name replacement, duplicate keys."""

from __future__ import annotations

import asyncio
import threading
import uuid
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from catalog.domain.identity import entity_id
from catalog.importers.base import ImporterDataError, ImporterError, Record
from catalog.importers.fixture import FixtureImporter, ensure_dev_source
from catalog.importers.loader import ImportFailed, ImportInProgress, run_import
from tests.importers.support import V1, mutated_snapshot, rows

Sessions = async_sessionmaker[AsyncSession]


@pytest_asyncio.fixture(autouse=True)
async def fixture_sources(sessionmaker: Sessions) -> None:
    async with sessionmaker.begin() as session:
        for code in ("fixture", "fixture_b"):
            await ensure_dev_source(session, code)


async def test_a_product_links_to_a_composition_of_another_source_once_it_exists(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    def point_at_b(data: dict[str, Any]) -> None:
        data["products"][0]["composition_source"] = "fixture_b"

    snapshot = mutated_snapshot(tmp_path, point_at_b)
    first = await run_import(sessionmaker, FixtureImporter(), snapshot)
    assert first.counts["products_unlinked"] == 1

    await run_import(sessionmaker, FixtureImporter(source="fixture_b"), V1)
    second = await run_import(sessionmaker, FixtureImporter(), snapshot)

    linked = await rows(
        engine, "SELECT composition_id FROM catalog.products WHERE source_key = 'P-TEST-500'"
    )
    assert linked[0][0] == entity_id("fixture_b", "composition", "C-TEST-500")
    assert second.counts["products"]["updated"] == 1
    assert second.counts["products_unlinked"] == 0


class _Blocking(FixtureImporter):
    def __init__(self, started: threading.Event, release: threading.Event) -> None:
        super().__init__()
        self._started, self._release = started, release

    def parse(self, snapshot_dir: Path) -> Iterator[Record]:
        self._started.set()
        self._release.wait(timeout=30)
        return super().parse(snapshot_dir)


async def test_a_cancelled_run_is_marked_failed_not_left_running(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    started, release = threading.Event(), threading.Event()
    task = asyncio.create_task(run_import(sessionmaker, _Blocking(started, release), V1))
    try:
        await asyncio.to_thread(started.wait, 30)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
    finally:
        release.set()

    found = await rows(engine, "SELECT status, error_code FROM catalog.import_runs")
    assert [tuple(r) for r in found] == [("failed", "import_aborted")]
    await run_import(sessionmaker, FixtureImporter(), V1)  # the source is free again


async def _insert_running(sessions: Sessions, age_minutes: int) -> None:
    async with sessions.begin() as session:
        await session.execute(
            text(
                "INSERT INTO catalog.import_runs (id, source, snapshot_sha256, status, started_at)"
                " VALUES (:i, 'fixture', :h, 'running', now() - make_interval(mins => :m))"
            ),
            {"i": uuid.uuid4(), "h": "f" * 64, "m": age_minutes},
        )


async def test_a_stale_running_row_is_taken_over(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    await _insert_running(sessionmaker, age_minutes=7 * 60)

    await run_import(sessionmaker, FixtureImporter(), V1, stale_run_minutes=360)

    found = await rows(engine, "SELECT status, error_code FROM catalog.import_runs ORDER BY status")
    assert sorted(tuple(r) for r in found) == [("failed", "stale"), ("succeeded", None)]


async def test_a_fresh_running_row_still_blocks(sessionmaker: Sessions) -> None:
    await _insert_running(sessionmaker, age_minutes=1)

    with pytest.raises(ImportInProgress):
        await run_import(sessionmaker, FixtureImporter(), V1, stale_run_minutes=360)


async def test_database_errors_carry_no_bound_values(engine: AsyncEngine) -> None:
    sentinel = 7654321
    with pytest.raises(DBAPIError) as caught:
        async with engine.begin() as conn:
            # PostgreSQL does not echo the value, so only SQLAlchemy's parameters could leak it.
            await conn.execute(text("SELECT 1 / (CAST(:v AS int) - :v)"), {"v": sentinel})
    assert str(sentinel) not in str(caught.value)


def _break_a_package(data: dict[str, Any]) -> None:
    data["products"][2]["packages"] = [
        {"key": "P-BAD", "description": "SENTINEL", "count": "0", "count_unit": "x", "gtins": []}
    ]


async def test_an_unexpected_failure_is_import_failed_without_a_cause(
    sessionmaker: Sessions, tmp_path: Path
) -> None:
    with pytest.raises(ImportFailed) as caught:
        await run_import(
            sessionmaker, FixtureImporter(), mutated_snapshot(tmp_path, _break_a_package)
        )

    assert caught.value.__cause__ is None
    assert caught.value.__suppress_context__
    assert str(caught.value) == "import_failed"


async def test_names_of_another_source_survive_a_rename(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    await run_import(sessionmaker, FixtureImporter(), V1)
    substance = entity_id("fixture", "substance", "S-TEST")
    async with sessionmaker.begin() as session:
        await session.execute(
            text(
                "INSERT INTO catalog.substance_names (substance_id, lang, name, source) "
                "VALUES (:s, 'en', 'Foreign synonym', 'fixture_b')"
            ),
            {"s": substance},
        )

    def rename(data: dict[str, Any]) -> None:
        data["substances"][0]["name_en"] = "Renamed"

    await run_import(sessionmaker, FixtureImporter(), mutated_snapshot(tmp_path, rename))

    names = {r[0] for r in await rows(engine, "SELECT name FROM catalog.substance_names")}
    assert {"Foreign synonym", "Renamed"} <= names
    assert "Testamol" not in names


async def test_two_compositions_with_one_identity_in_a_source_are_rejected(
    sessionmaker: Sessions, tmp_path: Path
) -> None:
    def duplicate(data: dict[str, Any]) -> None:
        twin = dict(data["compositions"][0], key="C-TWIN")
        data["compositions"].append(twin)

    with pytest.raises(ImporterDataError) as caught:
        await run_import(sessionmaker, FixtureImporter(), mutated_snapshot(tmp_path, duplicate))

    assert caught.value.code == "duplicate_composition"


async def test_a_gtin_listed_for_two_packages_is_skipped_not_last_wins(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    def clash(data: dict[str, Any]) -> None:
        data["products"][0]["packages"][1]["gtins"].append("04607012345677")

    result = await run_import(sessionmaker, FixtureImporter(), mutated_snapshot(tmp_path, clash))

    stored = {r[0] for r in await rows(engine, "SELECT gtin FROM catalog.gtins")}
    assert "04607012345677" not in stored
    assert "05901234123457" in stored
    assert result.counts["gtins_skipped"] == 3  # restricted, bad check digit, ambiguous


def test_importer_errors_are_plain_codes() -> None:
    assert str(ImporterError("x")) == "x"
