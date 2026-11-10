"""The export endpoints under abuse: shared login bucket, fail-closed limits, session liveness,
daily cap, download cap, key availability, refusal headers, sign-out (ADR 0016 section 8)."""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import pytest
from httpx import AsyncClient
from pydantic import SecretStr
from redis.asyncio import Redis
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.config import Settings
from app.ratelimit import RateLimiter
from tests.conftest import EXPORT_KEY_2, FakeClock
from tests.export_helpers import (
    download_export,
    export_row,
    export_status,
    request_export,
    requested_and_built,
    run_builder,
)
from tests.grace_helpers import app_of, login
from tests.helpers import register

pytestmark = pytest.mark.usefixtures("export_on")


@asynccontextmanager
async def limiter_down(client: AsyncClient, settings: Settings) -> AsyncIterator[None]:
    """The rate limiter cannot reach Redis (the rest of the app is untouched)."""
    app = app_of(client)
    live = app.state.rate_limiter
    dead: Redis = Redis.from_url(
        "redis://127.0.0.1:1/0", socket_connect_timeout=0.2, socket_timeout=0.2
    )
    app.state.rate_limiter = RateLimiter(dead, settings)
    try:
        yield
    finally:
        app.state.rate_limiter = live
        await dead.aclose()


async def expire_refresh_tokens(engine: AsyncEngine, user_id: str) -> None:
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "UPDATE refresh_tokens SET expires_at = now() - interval '1 day' WHERE user_id = :u"
            ),
            {"u": uuid.UUID(user_id)},
        )


# --- step-up ----------------------------------------------------------------------------------


async def test_password_guesses_share_the_login_bucket(
    client: AsyncClient, settings: Settings
) -> None:
    user = await register(client)
    for _ in range(settings.rate_limit_auth_max_attempts):
        wrong = await request_export(client, user, password="wrong password")
        assert wrong.status_code == 401
    assert (await request_export(client, user, password="wrong password")).status_code == 429
    # The guesses spent the budget of the sign-in too: the right password is throttled as well.
    assert (await login(client, user.email, user.password)).status_code == 429


async def test_the_step_up_and_the_download_fail_closed_without_redis(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
) -> None:
    user = await register(client)
    export_id = await requested_and_built(client, maker, settings, user, clock())
    async with limiter_down(client, settings):
        asked = await request_export(client, user)
        assert (asked.status_code, asked.json()["error"]["code"]) == (
            503,
            "rate_limit_unavailable",
        )
        refused = await download_export(client, user, export_id)
        assert refused.status_code == 503
        # Status polling is not a secret-guarded scope: it stays open.
        assert (await export_status(client, user, export_id)).status_code == 200
    assert (await download_export(client, user, export_id)).status_code == 200  # nothing was lost


# --- session liveness -------------------------------------------------------------------------


async def test_the_request_needs_a_live_session(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    await expire_refresh_tokens(engine, user.id)  # expired, but not revoked
    resp = await request_export(client, user)
    assert (resp.status_code, resp.json()["error"]["code"]) == (401, "invalid_token")


async def test_a_session_with_an_expired_refresh_token_cannot_download(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
) -> None:
    user = await register(client)
    export_id = await requested_and_built(client, maker, settings, user, clock())
    await expire_refresh_tokens(engine, user.id)
    assert (await download_export(client, user, export_id)).status_code == 404
    assert (await export_row(engine, export_id)).status == "ready"  # nothing was claimed


async def test_signing_out_drops_the_archive_of_that_session(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
) -> None:
    user = await register(client)
    export_id = await requested_and_built(client, maker, settings, user, clock())
    queued = await register(client)
    queued_id = (await request_export(client, queued)).json()["id"]
    for who in (user, queued):
        out = await client.post("/v1/auth/logout", json={"refresh_token": who.refresh_token})
        assert out.status_code == 204
    for export in (export_id, queued_id):
        row = await export_row(engine, export)
        assert (row.status, row.archive) == ("expired", None)
    assert (await run_builder(maker, settings, clock())).built == 0  # the queued one is gone


async def test_a_password_reset_drops_the_archives_of_every_session(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
) -> None:
    from tests.helpers import last_code

    user = await register(client)
    export_id = await requested_and_built(client, maker, settings, user, clock())
    assert (
        await client.post("/v1/auth/password-reset/request", json={"email": user.email})
    ).status_code == 202
    confirm = await client.post(
        "/v1/auth/password-reset/confirm",
        json={
            "email": user.email,
            "code": last_code(client, user.email, "password_reset"),
            "new_password": "another long password",
        },
    )
    assert confirm.status_code == 204
    row = await export_row(engine, export_id)
    assert (row.status, row.archive) == ("expired", None)


# --- limits -----------------------------------------------------------------------------------


async def test_a_failed_export_does_not_start_the_cooldown(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    first = (await request_export(client, user)).json()["id"]
    async with engine.begin() as conn:
        await conn.execute(
            text("UPDATE data_exports SET status='failed', error_code='export_build_failed'")
        )
    retry = await request_export(client, user)
    assert retry.status_code == 202
    assert retry.json()["id"] != first


async def test_exports_per_day_are_capped_and_downloaded_ones_count(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(settings, "export_max_per_day", 2)
    user = await register(client)
    for _ in range(2):
        export_id = await requested_and_built(client, maker, settings, user, clock())
        assert (await download_export(client, user, export_id)).status_code == 200
        clock.advance(minutes=1)
    capped = await request_export(client, user)
    assert (capped.status_code, capped.json()["error"]["code"]) == (429, "export_rate_limited")
    assert 0 < int(capped.headers["retry-after"]) <= 24 * 3600
    clock.advance(hours=24)
    assert (await request_export(client, user)).status_code == 202


async def test_downloads_in_flight_are_capped_and_the_export_survives_the_refusal(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
) -> None:
    user = await register(client)
    export_id = await requested_and_built(client, maker, settings, user, clock())
    app = app_of(client)
    live = app.state.export_download_slots
    app.state.export_download_slots = asyncio.Semaphore(0)  # every slot taken
    try:
        busy = await download_export(client, user, export_id)
    finally:
        app.state.export_download_slots = live
    assert (busy.status_code, busy.json()["error"]["code"]) == (503, "export_busy")
    assert busy.headers["retry-after"]
    assert (await download_export(client, user, export_id)).status_code == 200


async def test_the_default_download_cap_is_two(client: AsyncClient) -> None:
    assert app_of(client).state.export_download_slots._value == 2


# --- keys, headers ----------------------------------------------------------------------------


async def test_an_export_whose_key_left_the_ring_is_kept_not_lost(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    user = await register(client)
    export_id = await requested_and_built(client, maker, settings, user, clock())  # key 1
    keys, current = settings.data_encryption_keys, settings.data_encryption_key_id
    monkeypatch.setattr(settings, "data_encryption_keys", {2: SecretStr(EXPORT_KEY_2)})
    monkeypatch.setattr(settings, "data_encryption_key_id", 2)
    refused = await download_export(client, user, export_id)
    assert (refused.status_code, refused.json()["error"]["code"]) == (500, "export_unavailable")
    row = await export_row(engine, export_id)
    assert (row.status, row.archive is not None) == ("ready", True)  # the claim was rolled back
    monkeypatch.setattr(settings, "data_encryption_keys", keys)
    monkeypatch.setattr(settings, "data_encryption_key_id", current)
    assert (await download_export(client, user, export_id)).status_code == 200


async def test_refusals_and_the_archive_are_not_cached_or_sniffed(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
) -> None:
    user = await register(client)
    export_id = (await request_export(client, user)).json()["id"]
    early = await download_export(client, user, export_id)  # 409 not ready
    missing = await download_export(client, user, str(uuid.uuid4()))  # 404
    status_404 = await export_status(client, user, str(uuid.uuid4()))
    await run_builder(maker, settings, clock())
    ok = await download_export(client, user, export_id)
    gone = await download_export(client, user, export_id)  # 410
    for resp, code in ((early, 409), (missing, 404), (status_404, 404), (ok, 200), (gone, 410)):
        assert resp.status_code == code
        assert resp.headers["cache-control"] == "no-store"
        assert resp.headers["x-content-type-options"] == "nosniff"
    assert (await export_status(client, user, export_id)).headers["cache-control"] == "no-store"
