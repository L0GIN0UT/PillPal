"""The export builder (`build_data_exports`): claim, build, expire, retention (ADR 0016 §8)."""

from __future__ import annotations

import asyncio
import json
import uuid
from datetime import timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

import app.jobs.data_exports as job
from app.config import Settings
from app.services.data_encryption import EXPORT_PURPOSE, DataKeyring
from tests.conftest import FakeClock
from tests.export_helpers import (
    export_row,
    insert_export,
    request_export,
    run_builder,
    zip_members,
)
from tests.grace_helpers import count
from tests.helpers import create_medication, register

pytestmark = pytest.mark.usefixtures("export_on")

BLOB = b"\x01" + bytes(12) + b"ciphertext-and-tag-padding"


async def queue(client: AsyncClient, user: Any) -> str:
    resp = await request_export(client, user)
    assert resp.status_code == 202, resp.text
    return str(resp.json()["id"])


async def test_a_queued_export_is_built_and_encrypted_under_the_current_key(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
) -> None:
    user = await register(client)
    await create_medication(client, user, name="Cyrillic-Тест")
    export_id = await queue(client, user)

    report = await run_builder(maker, settings, clock())
    assert (report.built, report.failed) == (1, 0)

    row = await export_row(engine, export_id)
    assert row.status == "ready"
    assert row.lease_until is None
    assert row.ready_at == clock()
    assert row.expires_at == clock() + timedelta(hours=settings.export_ttl_hours)
    ring = DataKeyring.from_settings(settings)
    assert ring is not None
    plain = ring.decrypt(EXPORT_PURPOSE, uuid.UUID(export_id), bytes(row.archive))
    assert row.size_bytes == len(plain)  # the zip, not the ciphertext
    members = zip_members(plain)
    assert json.loads(members["manifest.json"])["format_version"] == 1
    assert "Cyrillic-Тест" in members["tables/medications.json"].decode()


async def test_a_run_with_nothing_to_do_changes_nothing(
    maker: async_sessionmaker[AsyncSession], settings: Settings, clock: FakeClock
) -> None:
    report = await run_builder(maker, settings, clock())
    assert (report.expired, report.deleted, report.built, report.failed) == (0, 0, 0, 0)


async def test_accounts_pending_deletion_are_skipped(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
) -> None:
    user = await register(client)
    export_id = await queue(client, user)
    async with engine.begin() as conn:  # a request that bypassed the deletion transaction
        await conn.execute(
            text(
                "UPDATE users SET deletion_requested_at = now(), "
                "erase_after = now() + interval '1 day' WHERE id = :u"
            ),
            {"u": uuid.UUID(user.id)},
        )
    assert (await run_builder(maker, settings, clock())).built == 0
    assert (await export_row(engine, export_id)).status == "queued"


async def test_an_archive_over_the_cap_fails_with_export_too_large(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    user = await register(client)
    export_id = await queue(client, user)
    monkeypatch.setattr(settings, "export_max_bytes", 10)
    report = await run_builder(maker, settings, clock())
    assert (report.built, report.failed) == (0, 1)
    row = await export_row(engine, export_id)
    assert (row.status, row.error_code, row.archive) == ("failed", "export_too_large", None)


async def test_a_build_error_fails_the_export_without_leaking_its_text(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    user = await register(client)
    export_id = await queue(client, user)

    async def boom(*_: object, **__: object) -> None:
        raise RuntimeError("needle-medication-name")

    monkeypatch.setattr(job, "collect_account_data", boom)
    report = await run_builder(maker, settings, clock())
    assert report.failed == 1
    row = await export_row(engine, export_id)
    assert (row.status, row.error_code) == ("failed", "export_build_failed")
    captured = capsys.readouterr()
    assert "needle-medication-name" not in captured.out + captured.err


async def test_a_build_whose_lease_expired_is_failed_not_rebuilt_and_a_live_one_is_left_alone(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
) -> None:
    crashed, busy = await register(client), await register(client)
    stale = await insert_export(
        engine,
        crashed.id,
        status="running",
        requested_at=clock() - timedelta(minutes=30),
        lease_until=clock() - timedelta(minutes=1),
    )
    live = await insert_export(
        engine,
        busy.id,
        status="running",
        requested_at=clock() - timedelta(minutes=30),
        lease_until=clock() + timedelta(minutes=10),
    )
    report = await run_builder(maker, settings, clock())
    assert (report.built, report.abandoned) == (0, 1)
    # A build that kills its worker must not kill the next one: failed, not retried.
    row = await export_row(engine, stale)
    assert (row.status, row.error_code, row.lease_until) == (
        "failed",
        "export_build_failed",
        None,
    )
    assert (await export_row(engine, live)).status == "running"
    again = await run_builder(maker, settings, clock())
    assert (again.built, again.abandoned) == (0, 0)


async def test_a_result_is_dropped_when_the_lease_was_taken_over_meanwhile(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    user = await register(client)
    export_id = await queue(client, user)
    real_build = job._build

    async def slow_build(*args: Any, **kwargs: Any) -> bytes:
        blob = await real_build(*args, **kwargs)
        async with engine.begin() as conn:  # another worker re-claimed the row meanwhile
            await conn.execute(
                text("UPDATE data_exports SET lease_until = lease_until + interval '1 hour'")
            )
        return blob

    monkeypatch.setattr(job, "_build", slow_build)
    report = await run_builder(maker, settings, clock())
    assert report.built == 0
    row = await export_row(engine, export_id)
    assert (row.status, row.archive) == ("running", None)


async def test_two_runs_at_once_build_each_export_once(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
) -> None:
    users = [await register(client) for _ in range(2)]
    for user in users:
        await queue(client, user)
    assert settings.export_builds_per_run == 1  # one build per run: two runs share two exports
    first, second = await asyncio.gather(
        run_builder(maker, settings, clock()), run_builder(maker, settings, clock())
    )
    assert first.built + second.built == 2
    assert await count(engine, "data_exports", "status = 'ready'") == 2


async def test_builds_per_run_are_capped(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
    engine: AsyncEngine,
) -> None:
    for _ in range(2):
        await queue(client, await register(client))
    assert (await run_builder(maker, settings, clock())).built == 1  # the default is one a run
    assert await count(engine, "data_exports", "status = 'queued'") == 1
    monkeypatch.setattr(settings, "export_builds_per_run", 5)
    assert (await run_builder(maker, settings, clock())).built == 1


async def test_ready_exports_expire_and_lose_their_archive(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
) -> None:
    user = await register(client)
    due = await insert_export(
        engine,
        user.id,
        status="ready",
        requested_at=clock() - timedelta(hours=26),
        ready_at=clock() - timedelta(hours=25),
        expires_at=clock() - timedelta(hours=1),
        archive=BLOB,
    )
    other = await register(client)
    open_export = await insert_export(
        engine,
        other.id,
        status="ready",
        requested_at=clock() - timedelta(hours=2),
        ready_at=clock() - timedelta(hours=1),
        expires_at=clock() + timedelta(hours=23),
        archive=BLOB,
    )
    report = await run_builder(maker, settings, clock())
    assert report.expired == 1
    row = await export_row(engine, due)
    assert (row.status, row.archive) == ("expired", None)
    kept = await export_row(engine, open_export)
    assert (kept.status, bytes(kept.archive)) == ("ready", BLOB)


async def test_metadata_is_deleted_after_the_retention(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
) -> None:
    user = await register(client)
    old = await insert_export(
        engine,
        user.id,
        status="downloaded",
        requested_at=clock() - timedelta(days=settings.export_retention_days, seconds=1),
    )
    recent = await insert_export(
        engine,
        user.id,
        status="downloaded",
        requested_at=clock() - timedelta(days=settings.export_retention_days) + timedelta(hours=1),
    )
    assert (await run_builder(maker, settings, clock())).deleted == 1
    assert await export_row(engine, old) is None
    assert await export_row(engine, recent) is not None


async def test_with_the_flag_off_nothing_is_built_but_archives_still_expire(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    user, other = await register(client), await register(client)
    queued = await queue(client, user)
    expiring = await insert_export(
        engine,
        other.id,
        status="ready",
        requested_at=clock() - timedelta(hours=26),
        ready_at=clock() - timedelta(hours=25),
        expires_at=clock() - timedelta(hours=1),
        archive=BLOB,
    )
    monkeypatch.setattr(settings, "feature_data_export", False)
    report = await run_builder(maker, settings, clock())
    assert (report.built, report.expired) == (0, 1)
    assert (await export_row(engine, queued)).status == "queued"
    assert (await export_row(engine, expiring)).archive is None
