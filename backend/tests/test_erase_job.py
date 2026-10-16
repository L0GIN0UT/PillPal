"""The hourly erase job (ADR 0010 §5): batches, boundaries, races, failures."""

from __future__ import annotations

import asyncio
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from app.jobs import account_erasure
from tests.conftest import FakeClock
from tests.grace_helpers import (
    app_of,
    count,
    in_days,
    login,
    pending_login,
    request_deletion,
    restore,
    run_erase_job,
)
from tests.helpers import create_managed_profile, link_accounts, register
from tests.sync_helpers import push_as
from tests.test_sync import med_data, mut

_WAITING = "SELECT count(*) FROM pg_locks WHERE NOT granted"
GRACE = timedelta(days=30)
INTERVAL = timedelta(hours=1)


async def test_the_job_erases_every_due_account_in_one_run_across_batches(
    client: AsyncClient, engine: AsyncEngine, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "account_erasure_batch_size", 2)
    users = [await register(client) for _ in range(5)]
    survivor = await register(client)
    for user in users:
        await request_deletion(client, user)

    report = await run_erase_job(client, in_days(31))

    assert (report.erased, report.failed, report.overdue) == (5, 0, 0)
    assert await count(engine, "users") == 1
    assert (await client.get("/v1/me", headers=survivor.headers)).status_code == 200
    assert (await run_erase_job(client, in_days(31))).erased == 0  # nothing left to do


async def test_nothing_is_erased_before_erase_after_and_all_of_it_at_that_instant(
    client: AsyncClient, clock: FakeClock
) -> None:
    user = await register(client)
    await request_deletion(client, user)
    erase_after = clock.now + GRACE - 2 * INTERVAL

    assert (await run_erase_job(client, erase_after - timedelta(microseconds=1))).erased == 0
    assert (await login(client, user.email, user.password)).status_code == 403  # still pending
    assert (await run_erase_job(client, erase_after)).erased == 1


async def test_one_failing_account_neither_stops_the_others_nor_loops(
    client: AsyncClient, engine: AsyncEngine, monkeypatch: pytest.MonkeyPatch
) -> None:
    bad, good = await register(client), await register(client)
    for user in (bad, good):
        await request_deletion(client, user)
    real = account_erasure.erase_account

    async def flaky(session, user_id, **kwargs):  # type: ignore[no-untyped-def]
        if str(user_id) == bad.id:
            raise RuntimeError("synthetic failure")
        await real(session, user_id, **kwargs)

    monkeypatch.setattr(account_erasure, "erase_account", flaky)

    report = await run_erase_job(client, in_days(31))

    assert (report.erased, report.failed) == (1, 1)
    assert report.overdue == 1  # due for more than an interval and still there: alert on it
    assert await count(engine, "users", "id = :u", u=uuid.UUID(bad.id)) == 1
    assert await count(engine, "users", "id = :u", u=uuid.UUID(good.id)) == 0


async def test_two_workers_at_once_erase_each_account_once(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    users = [await register(client) for _ in range(4)]
    for user in users:
        await request_deletion(client, user)

    first, second = await asyncio.gather(
        run_erase_job(client, in_days(31)), run_erase_job(client, in_days(31))
    )

    assert first.erased + second.erased == 4
    assert first.failed == second.failed == 0
    assert await count(engine, "users") == 0


# --- restore and job on one account: exactly one wins -----------------------------------------


async def test_a_row_held_past_the_lock_timeout_is_left_for_the_next_run(
    client: AsyncClient, engine: AsyncEngine, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        app_of(client).state.settings, "account_erasure_retry_lock_timeout_seconds", 1
    )
    user = await register(client)
    await request_deletion(client, user)
    async with engine.connect() as conn:
        await conn.execute(
            text("SELECT 1 FROM users WHERE id = :u FOR NO KEY UPDATE"), {"u": uuid.UUID(user.id)}
        )  # what a restore in progress holds
        report = await asyncio.wait_for(run_erase_job(client, in_days(31)), timeout=10)
        await conn.rollback()
    assert report.erased == 0  # the retry gave up after lock_timeout instead of hanging
    assert report.failed == 0
    assert await count(engine, "users", "id = :u", u=uuid.UUID(user.id)) == 1


async def test_a_restore_before_the_job_wins(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    await request_deletion(client, user)
    ticket, code = await pending_login(client, user)
    assert (await restore(client, ticket, code)).status_code == 200

    assert (await run_erase_job(client, in_days(31))).erased == 0
    assert await count(engine, "users", "id = :u", u=uuid.UUID(user.id)) == 1


async def test_a_job_before_the_restore_wins(client: AsyncClient) -> None:
    user = await register(client)
    await request_deletion(client, user)
    ticket, code = await pending_login(client, user)

    assert (await run_erase_job(client, in_days(31))).erased == 1

    assert (await restore(client, ticket, code)).status_code == 401


# --- what the erased account leaves in other people's profiles ---------------------------------


async def test_device_ids_of_the_erased_account_vanish_from_foreign_rows(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, helper = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, helper, "guardian", ward)
    medication_id = str(uuid.uuid4())
    await push_as(
        client,
        owner,
        [mut("medication", "upsert", str(uuid.uuid4()), med_data(ward))],
        device="owner-phone",
    )
    written = await push_as(
        client,
        helper,
        [mut("medication", "upsert", medication_id, med_data(ward), 4)],
        device="helper-phone",
    )
    assert written[0]["status"] == "applied"
    where = "updated_by_device = :d"
    assert await count(engine, "medications", where, d="helper-phone") == 1

    await request_deletion(client, helper)
    await run_erase_job(client, in_days(31))

    assert await count(engine, "medications", where, d="helper-phone") == 0
    assert await count(engine, "medications", where, d="owner-phone") == 1  # others keep theirs
    assert await count(engine, "medications", "id = :m", m=uuid.UUID(medication_id)) == 1


async def test_the_default_clock_is_the_wall_clock(client: AsyncClient) -> None:
    from app.jobs.account_erasure import erase_expired_accounts

    app = app_of(client)
    report = await erase_expired_accounts(app.state.sessionmaker, app.state.settings)
    assert report.erased == 0


async def test_an_account_held_during_the_first_pass_is_erased_in_the_same_run(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    """SKIP LOCKED must not push an account past its deadline: a skipped one is retried once."""
    user = await register(client)
    assert (await request_deletion(client, user)).status_code == 204

    async with engine.connect() as holder:
        await holder.execute(
            text("SELECT id FROM users WHERE id = :id FOR NO KEY UPDATE"), {"id": user.id}
        )
        job = asyncio.create_task(run_erase_job(client, datetime.now(UTC) + timedelta(days=31)))
        for _ in range(200):  # the retry pass is blocked on the row once it waits for a lock
            if (await holder.execute(text(_WAITING))).scalar_one():
                break
            await asyncio.sleep(0.02)
        else:
            raise AssertionError("the job never retried the skipped account")
        await holder.rollback()

    report = await asyncio.wait_for(job, timeout=10)
    assert report.erased_ids == [uuid.UUID(user.id)]
    assert await count(engine, "users", "id = :id", id=user.id) == 0


async def test_a_restore_that_holds_the_row_through_the_retry_still_wins(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    assert (await request_deletion(client, user)).status_code == 204

    async with engine.connect() as holder:
        await holder.execute(
            text("SELECT id FROM users WHERE id = :id FOR NO KEY UPDATE"), {"id": user.id}
        )
        job = asyncio.create_task(run_erase_job(client, datetime.now(UTC) + timedelta(days=31)))
        for _ in range(200):
            if (await holder.execute(text(_WAITING))).scalar_one():
                break
            await asyncio.sleep(0.02)
        await holder.execute(
            text(
                "UPDATE users SET deletion_requested_at = NULL, erase_after = NULL WHERE id = :id"
            ),
            {"id": user.id},
        )
        await holder.commit()

    report = await asyncio.wait_for(job, timeout=10)
    assert report.erased == 0
    assert await count(engine, "users", "id = :id", id=user.id) == 1
