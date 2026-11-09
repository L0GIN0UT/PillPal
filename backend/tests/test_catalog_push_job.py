"""The ARQ job that pushes the GTIN confirmation snapshot (ADR 0014 section 3).

State that must survive a restart and be shared by several workers (the next attempt, the lock,
the "already retracted" mark) lives in Redis; the clock is injected.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from typing import Any

import httpx
import pytest
import pytest_asyncio
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.catalog_client import CatalogIngestClient
from app.config import Settings
from app.worker import (
    CONTRIBUTION_LOCK_KEY,
    CONTRIBUTION_NEXT_AT_KEY,
    CONTRIBUTION_RETRACTED_KEY,
    CONTRIBUTION_RETRY_SECONDS,
    JobFailed,
    WorkerSettings,
    on_shutdown,
    on_startup,
    push_gtin_confirmations_job,
)
from tests.catalog_helpers import GTIN
from tests.conftest import TEST_REDIS_URL, FakeClock, make_settings
from tests.test_catalog_client import TOKEN, Recorder, enabled

pytestmark = pytest.mark.usefixtures("contributions_on")


@pytest_asyncio.fixture
async def redis() -> AsyncIterator[Redis]:
    connection: Redis = Redis.from_url(TEST_REDIS_URL)
    await connection.flushdb()
    yield connection
    await connection.flushdb()
    await connection.aclose()


def ctx_for(
    settings: Settings,
    recorder: Recorder,
    maker: async_sessionmaker[AsyncSession],
    clock: FakeClock,
    redis: Redis,
) -> dict[str, Any]:
    return {
        "settings": settings,
        "maker": maker,
        "now": clock,
        "redis": redis,
        "catalog_client": CatalogIngestClient(settings, transport=httpx.MockTransport(recorder)),
    }


def test_the_job_is_registered_with_a_cron_that_runs_every_minute() -> None:
    cron = {c.name: c for c in WorkerSettings.cron_jobs}["push_gtin_confirmations"]
    assert (cron.second, cron.minute, cron.hour) == (0, None, None)
    assert "push_gtin_confirmations" in {f.name for f in WorkerSettings.functions}
    assert cron.keep_result_s == 0


async def test_without_a_configured_catalog_nothing_happens(
    maker: async_sessionmaker[AsyncSession], now: FakeClock, redis: Redis
) -> None:
    ctx = {"settings": make_settings(), "maker": maker, "now": now, "redis": redis}
    await push_gtin_confirmations_job(ctx)  # no client: the feature was never configured
    assert await redis.keys("*") == []


async def test_the_interval_is_kept_in_redis_so_a_restart_or_a_second_worker_respects_it(
    maker: async_sessionmaker[AsyncSession], now: FakeClock, redis: Redis
) -> None:
    recorder = Recorder()
    settings = enabled(catalog_contribution_interval_seconds=3600)
    await push_gtin_confirmations_job(ctx_for(settings, recorder, maker, now, redis))
    assert len(recorder.requests) == 1
    now.advance(minutes=59)
    # a fresh context = a restarted worker, or another process
    await push_gtin_confirmations_job(ctx_for(settings, recorder, maker, now, redis))
    assert len(recorder.requests) == 1
    now.advance(minutes=2)
    await push_gtin_confirmations_job(ctx_for(settings, recorder, maker, now, redis))
    assert len(recorder.requests) == 2


async def test_the_run_is_claimed_before_sending_so_a_hang_does_not_start_a_second(
    maker: async_sessionmaker[AsyncSession], now: FakeClock, redis: Redis
) -> None:
    seen: list[bytes | None] = []
    settings = enabled()
    ctx = ctx_for(settings, Recorder(), maker, now, redis)
    original = ctx["catalog_client"].put_page

    async def claimed_first(**kwargs: Any) -> None:
        seen.append(await redis.get(CONTRIBUTION_NEXT_AT_KEY))
        seen.append(await redis.get(CONTRIBUTION_LOCK_KEY))
        await original(**kwargs)

    ctx["catalog_client"].put_page = claimed_first
    await push_gtin_confirmations_job(ctx)
    assert seen[0] is not None  # next_at was written before the first page went out
    assert seen[1] is not None  # and so was the cross-process lock
    assert await redis.get(CONTRIBUTION_LOCK_KEY) is None  # released afterwards


async def test_two_workers_never_push_at_the_same_time(
    maker: async_sessionmaker[AsyncSession], now: FakeClock, redis: Redis
) -> None:
    gate = asyncio.Event()
    calls = 0

    async def slow(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        await gate.wait()
        return httpx.Response(200, json={})

    settings = enabled()

    def worker() -> dict[str, Any]:
        ctx = ctx_for(settings, Recorder(), maker, now, redis)
        ctx["catalog_client"] = CatalogIngestClient(settings, transport=httpx.MockTransport(slow))
        return ctx

    first = asyncio.create_task(push_gtin_confirmations_job(worker()))
    await asyncio.sleep(0.3)
    await push_gtin_confirmations_job(worker())  # the lock is held: returns at once
    gate.set()
    await first
    assert calls == 1


@pytest.mark.parametrize("failure", ["status", "transport", "unexpected"])
async def test_every_kind_of_failure_gets_the_retry_backoff_and_leaks_nothing(
    failure: str,
    maker: async_sessionmaker[AsyncSession],
    now: FakeClock,
    redis: Redis,
    capfd: pytest.CaptureFixture[str],
) -> None:
    def broken(request: httpx.Request) -> httpx.Response:
        if failure == "status":
            return httpx.Response(500, json={})
        if failure == "transport":
            raise httpx.ConnectError("http://catalog-private down", request=request)
        raise RuntimeError(f"boom {TOKEN} {GTIN}")

    settings = enabled(catalog_contribution_interval_seconds=7200)
    ctx = ctx_for(settings, Recorder(), maker, now, redis)
    ctx["catalog_client"] = CatalogIngestClient(settings, transport=httpx.MockTransport(broken))
    with pytest.raises(JobFailed) as raised:
        await push_gtin_confirmations_job(ctx)
    assert raised.value.__cause__ is None
    next_at = float(await redis.get(CONTRIBUTION_NEXT_AT_KEY) or 0)
    assert next_at == pytest.approx(now().timestamp() + CONTRIBUTION_RETRY_SECONDS)
    assert await redis.get(CONTRIBUTION_LOCK_KEY) is None
    out = capfd.readouterr()
    logged = out.out + out.err
    assert "catalog_push_failed" in logged
    for secret in (TOKEN, GTIN, "catalog-private"):
        assert secret not in logged


async def test_a_failure_is_retried_after_the_backoff_not_every_minute(
    maker: async_sessionmaker[AsyncSession], now: FakeClock, redis: Redis
) -> None:
    recorder = Recorder(500, 200)
    ctx = ctx_for(enabled(), recorder, maker, now, redis)
    with pytest.raises(JobFailed):
        await push_gtin_confirmations_job(ctx)
    now.advance(seconds=CONTRIBUTION_RETRY_SECONDS - 60)
    await push_gtin_confirmations_job(ctx)
    assert len(recorder.requests) == 1
    now.advance(seconds=61)
    await push_gtin_confirmations_job(ctx)
    assert len(recorder.requests) == 2


# --- retraction ---------------------------------------------------------------------------------


async def test_disabling_the_feature_sends_one_empty_snapshot_and_then_stays_quiet(
    maker: async_sessionmaker[AsyncSession], now: FakeClock, redis: Redis
) -> None:
    recorder = Recorder()
    settings = enabled(catalog_contributions_enabled=False)  # url and token stay configured
    ctx = ctx_for(settings, recorder, maker, now, redis)
    await push_gtin_confirmations_job(ctx)
    (body,) = recorder.bodies()
    assert (body["complete"], body["items"]) == (True, [])
    now.advance(hours=5)
    await push_gtin_confirmations_job(ctx)
    assert len(recorder.requests) == 1  # once
    assert await redis.get(CONTRIBUTION_RETRACTED_KEY) is not None


async def test_enabling_again_resumes_snapshots_and_a_later_disable_retracts_again(
    maker: async_sessionmaker[AsyncSession], now: FakeClock, redis: Redis
) -> None:
    recorder = Recorder()
    off = ctx_for(enabled(catalog_contributions_enabled=False), recorder, maker, now, redis)
    on = ctx_for(enabled(), recorder, maker, now, redis)
    await push_gtin_confirmations_job(off)
    now.advance(hours=2)
    await push_gtin_confirmations_job(on)
    assert await redis.get(CONTRIBUTION_RETRACTED_KEY) is None
    now.advance(hours=2)
    await push_gtin_confirmations_job(off)
    assert len(recorder.requests) == 3


async def test_the_explicit_retract_flag_wins_even_while_enabled(
    maker: async_sessionmaker[AsyncSession], now: FakeClock, redis: Redis
) -> None:
    recorder = Recorder()
    settings = enabled(catalog_contributions_retract=True)
    await push_gtin_confirmations_job(ctx_for(settings, recorder, maker, now, redis))
    (body,) = recorder.bodies()
    assert body["items"] == []


# --- startup ------------------------------------------------------------------------------------


async def test_startup_builds_the_client_when_the_catalog_is_configured_and_closes_it(
    maker: async_sessionmaker[AsyncSession],
) -> None:
    unconfigured: dict[str, Any] = {"settings": make_settings(), "maker": maker, "senders": {}}
    await on_startup(unconfigured)
    assert "catalog_client" not in unconfigured
    await on_shutdown(unconfigured)
    # disabled but configured: the client exists so that a disable can retract
    configured: dict[str, Any] = {
        "settings": enabled(catalog_contributions_enabled=False),
        "maker": maker,
        "senders": {},
    }
    await on_startup(configured)
    assert isinstance(configured["catalog_client"], CatalogIngestClient)
    await on_shutdown(configured)
    assert configured["catalog_client"]._http.is_closed
