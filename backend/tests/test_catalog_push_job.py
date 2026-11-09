"""The ARQ job that pushes the GTIN confirmation snapshot (ADR 0014 section 3)."""

from __future__ import annotations

from typing import Any

import httpx
import pytest
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.catalog_client import CatalogIngestClient
from app.worker import (
    CONTRIBUTION_RETRY_SECONDS,
    JobFailed,
    WorkerSettings,
    on_shutdown,
    on_startup,
    push_gtin_confirmations_job,
)
from tests.catalog_helpers import GTIN
from tests.conftest import FakeClock, make_settings
from tests.test_catalog_client import TOKEN, Recorder, enabled

pytestmark = pytest.mark.usefixtures("contributions_on")


def ctx_for(
    settings: Any, recorder: Recorder, maker: async_sessionmaker[AsyncSession], clock: FakeClock
) -> dict[str, Any]:
    return {
        "settings": settings,
        "maker": maker,
        "now": clock,
        "catalog_client": CatalogIngestClient(settings, transport=httpx.MockTransport(recorder)),
    }


def test_the_job_is_registered_with_a_cron_that_runs_every_minute() -> None:
    cron = {c.name: c for c in WorkerSettings.cron_jobs}["push_gtin_confirmations"]
    assert (cron.second, cron.minute, cron.hour) == (0, None, None)
    assert "push_gtin_confirmations" in {f.name for f in WorkerSettings.functions}
    assert cron.keep_result_s == 0


async def test_a_disabled_feature_sends_nothing(
    maker: async_sessionmaker[AsyncSession], now: FakeClock
) -> None:
    recorder = Recorder()
    settings = make_settings()  # contributions off
    ctx = ctx_for(enabled(), recorder, maker, now)
    ctx["settings"] = settings
    await push_gtin_confirmations_job(ctx)
    assert recorder.requests == []


async def test_the_interval_gates_the_runs_and_the_clock_is_injected(
    maker: async_sessionmaker[AsyncSession], now: FakeClock
) -> None:
    recorder = Recorder()
    settings = enabled(catalog_contribution_interval_seconds=3600)
    ctx = ctx_for(settings, recorder, maker, now)
    await push_gtin_confirmations_job(ctx)
    assert len(recorder.requests) == 1
    now.advance(minutes=59)
    await push_gtin_confirmations_job(ctx)
    assert len(recorder.requests) == 1
    now.advance(minutes=2)
    await push_gtin_confirmations_job(ctx)
    assert len(recorder.requests) == 2


async def test_a_failure_is_retried_soon_but_not_every_minute_and_leaks_nothing(
    maker: async_sessionmaker[AsyncSession],
    now: FakeClock,
    capfd: pytest.CaptureFixture[str],
) -> None:
    recorder = Recorder(500, 200)
    ctx = ctx_for(enabled(), recorder, maker, now)
    with pytest.raises(JobFailed) as raised:
        await push_gtin_confirmations_job(ctx)
    assert raised.value.__cause__ is None
    now.advance(seconds=CONTRIBUTION_RETRY_SECONDS - 60)
    await push_gtin_confirmations_job(ctx)  # still backing off
    assert len(recorder.requests) == 1
    now.advance(seconds=61)
    await push_gtin_confirmations_job(ctx)
    assert len(recorder.requests) == 2
    out = capfd.readouterr()
    logged = out.out + out.err
    assert "catalog_push_failed" in logged
    assert "500" in logged  # the HTTP status is the only detail
    assert TOKEN not in logged
    assert GTIN not in logged
    assert "catalog-private" not in logged


async def test_startup_builds_the_client_only_when_enabled_and_shutdown_closes_it(
    maker: async_sessionmaker[AsyncSession],
) -> None:
    off: dict[str, Any] = {"settings": make_settings(), "maker": maker, "senders": {}}
    await on_startup(off)
    assert "catalog_client" not in off
    await on_shutdown(off)
    on: dict[str, Any] = {"settings": enabled(), "maker": maker, "senders": {}}
    await on_startup(on)
    assert isinstance(on["catalog_client"], CatalogIngestClient)
    await on_shutdown(on)
    assert on["catalog_client"]._http.is_closed
