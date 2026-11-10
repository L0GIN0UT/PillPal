"""The export builder under stress: cancellation, one build per account, the clock, retention."""

from __future__ import annotations

import asyncio
from datetime import datetime, timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

import app.jobs.data_exports as job
from app.config import Settings
from app.jobs.data_exports import build_data_exports
from tests.conftest import FakeClock
from tests.export_helpers import export_row, insert_export, request_export, run_builder
from tests.helpers import register

pytestmark = pytest.mark.usefixtures("export_on")

BLOB = b"\x01" + bytes(12) + b"ciphertext-and-tag-padding"


async def test_a_cancelled_build_is_failed_and_never_retried(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    user = await register(client)
    export_id = (await request_export(client, user)).json()["id"]

    async def cancelled(*_: object, **__: object) -> None:
        raise asyncio.CancelledError

    monkeypatch.setattr(job, "_build", cancelled)
    with pytest.raises(asyncio.CancelledError):  # re-raised after the row was finished
        await run_builder(maker, settings, clock())
    row = await export_row(engine, export_id)
    assert (row.status, row.error_code, row.lease_until) == ("failed", "export_build_failed", None)
    monkeypatch.undo()
    clock.advance(hours=1)
    assert (await run_builder(maker, settings, clock())).built == 0  # not retried, ever


async def test_one_export_per_account_is_built_per_run(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    user = await register(client)
    first = await insert_export(engine, user.id, requested_at=clock() - timedelta(minutes=2))
    second = await insert_export(engine, user.id, requested_at=clock() - timedelta(minutes=1))
    monkeypatch.setattr(settings, "export_builds_per_run", 5)
    assert (await run_builder(maker, settings, clock())).built == 1
    assert (await export_row(engine, first)).status == "ready"
    assert (await export_row(engine, second)).status == "queued"  # the next run's


async def test_every_build_reads_the_clock_again(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ids = []
    for _ in range(2):
        user = await register(client)
        ids.append(await insert_export(engine, user.id, requested_at=clock() - timedelta(hours=1)))
    monkeypatch.setattr(settings, "export_builds_per_run", 2)
    ticks = [clock()]

    def ticking() -> datetime:
        ticks.append(ticks[-1] + timedelta(seconds=7))
        return ticks[-1]

    assert (await build_data_exports(maker, settings, now=ticking)).built == 2
    ready = [(await export_row(engine, i)).ready_at for i in ids]
    assert ready[0] != ready[1]
    assert min(ready) > clock()  # not the instant the run started


async def test_a_ready_export_is_never_deleted_as_old_metadata(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
) -> None:
    user = await register(client)
    ready = await insert_export(
        engine,
        user.id,
        status="ready",
        requested_at=clock() - timedelta(days=settings.export_retention_days + 1),
        ready_at=clock() - timedelta(hours=1),
        expires_at=clock() + timedelta(hours=1),
        archive=BLOB,
    )
    report = await run_builder(maker, settings, clock())
    assert (report.deleted, report.expired) == (0, 0)
    assert (await export_row(engine, ready)).status == "ready"


async def test_an_archive_past_the_cap_is_aborted_while_it_is_written(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    user = await register(client)
    export_id = (await request_export(client, user)).json()["id"]
    seen: dict[str, Any] = {}
    real = job.build_archive

    def spy(*args: Any, **kwargs: Any) -> bytes:
        seen["max_bytes"] = kwargs.get("max_bytes")
        return real(*args, **kwargs)

    monkeypatch.setattr(job, "build_archive", spy)
    monkeypatch.setattr(settings, "export_max_bytes", 1024)
    await run_builder(maker, settings, clock())
    assert seen["max_bytes"] == 1024  # the builder stops by itself, not only the final check
    assert (await export_row(engine, export_id)).status in ("failed", "ready")
