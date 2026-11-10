"""``/v1/me/export``: request, status, single download (Phase 5.5, ADR 0016 section 8)."""

from __future__ import annotations

import json
import uuid

import jwt
import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.config import Settings
from tests.conftest import FakeClock
from tests.export_helpers import (
    download_export,
    export_row,
    export_status,
    request_export,
    requested_and_built,
    run_builder,
    second_session,
    zip_members,
)
from tests.grace_helpers import app_of, count, sent_to
from tests.helpers import create_medication, register

pytestmark = pytest.mark.usefixtures("export_on")

NEEDLE_NAME = "Needle-Аспирин-7731"


# --- switch, authentication, step-up ----------------------------------------------------------


async def test_features_report_the_export_flag(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    user = await register(client)
    on = await client.get("/v1/me/features", headers=user.headers)
    assert on.json()["data_export_enabled"] is True
    monkeypatch.setattr(settings, "feature_data_export", False)
    off = await client.get("/v1/me/features", headers=user.headers)
    assert off.json()["data_export_enabled"] is False


async def test_everything_is_forbidden_while_the_flag_is_off(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    user = await register(client)
    monkeypatch.setattr(settings, "feature_data_export", False)
    some_id = str(uuid.uuid4())
    for resp in (
        await request_export(client, user),
        await export_status(client, user, some_id),
        await download_export(client, user, some_id),
    ):
        assert resp.status_code == 403
        assert resp.json()["error"]["code"] == "feature_disabled"


async def test_unauthenticated_requests_are_401(client: AsyncClient) -> None:
    some_id = str(uuid.uuid4())
    assert (await client.post("/v1/me/export", json={"password": "x" * 10})).status_code == 401
    assert (await client.get(f"/v1/me/export/{some_id}")).status_code == 401
    assert (await client.post(f"/v1/me/export/{some_id}/download")).status_code == 401


async def test_the_request_needs_the_password(
    client: AsyncClient, engine: AsyncEngine, clock: FakeClock
) -> None:
    user = await register(client)
    # A missing proof is a 422, exactly like ``DELETE /v1/me``.
    assert (await client.post("/v1/me/export", headers=user.headers)).status_code == 422
    assert (await client.post("/v1/me/export", json={}, headers=user.headers)).status_code == 422
    wrong = await request_export(client, user, password="not the password")
    assert wrong.status_code == 401
    assert wrong.json()["error"]["code"] == "invalid_password"
    assert await count(engine, "data_exports") == 0
    assert sent_to(client, user.email, "export_requested") == []


async def test_an_unknown_body_field_is_422(client: AsyncClient) -> None:
    user = await register(client)
    resp = await client.post(
        "/v1/me/export", json={"password": user.password, "extra": 1}, headers=user.headers
    )
    assert resp.status_code == 422


async def test_a_token_without_sid_cannot_ask(client: AsyncClient) -> None:
    user = await register(client)
    old = app_of(client).state.tokens.issue_access(uuid.UUID(user.id))  # issued before ``sid``
    resp = await client.post(
        "/v1/me/export",
        json={"password": user.password},
        headers={"Authorization": f"Bearer {old}"},
    )
    assert resp.status_code == 401


async def test_login_and_refresh_put_the_family_into_sid(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)

    def sid(token: str) -> str:
        return str(jwt.decode(token, options={"verify_signature": False})["sid"])

    async def families() -> list[str]:
        async with engine.connect() as conn:
            rows = await conn.execute(
                text("SELECT DISTINCT family_id FROM refresh_tokens WHERE user_id = :u"),
                {"u": uuid.UUID(user.id)},
            )
            return [str(r[0]) for r in rows]

    assert [sid(user.access_token)] == await families()
    refreshed = await client.post("/v1/auth/refresh", json={"refresh_token": user.refresh_token})
    assert refreshed.status_code == 200
    assert sid(refreshed.json()["access_token"]) == sid(user.access_token)  # same session


# --- the full path ----------------------------------------------------------------------------


async def test_request_build_download_once(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
) -> None:
    user = await register(client)
    await create_medication(client, user, name=NEEDLE_NAME)

    created = await request_export(client, user)
    assert created.status_code == 202
    assert created.headers["cache-control"] == "private, no-store"
    export = created.json()
    assert export["status"] == "queued"
    export_id = export["id"]
    # Not ready yet: 409, and the status says so.
    early = await download_export(client, user, export_id)
    assert (early.status_code, early.json()["error"]["code"]) == (409, "export_not_ready")

    clock.advance(seconds=30)
    assert (await run_builder(maker, settings, clock())).built == 1
    status = (await export_status(client, user, export_id)).json()
    assert status["status"] == "ready"
    assert status["size_bytes"] > 0
    assert status["expires_at"] is not None

    got = await download_export(client, user, export_id)
    assert got.status_code == 200
    assert got.headers["content-type"] == "application/zip"
    assert got.headers["cache-control"] == "no-store"
    day = clock().strftime("%Y%m%d")
    assert got.headers["content-disposition"] == (
        f'attachment; filename="pillpal-export-ru-{day}.zip"'
    )
    members = zip_members(got.content)
    assert json.loads(members["manifest.json"])["region"] == "ru"
    assert NEEDLE_NAME in members["tables/medications.json"].decode()

    # Second download: gone, and nothing but metadata is left.
    again = await download_export(client, user, export_id)
    assert (again.status_code, again.json()["error"]["code"]) == (410, "export_gone")
    assert (await export_status(client, user, export_id)).json()["status"] == "downloaded"
    assert (await export_row(engine, export_id)).archive is None


async def test_the_download_does_not_depend_on_x_device_id(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
) -> None:
    user = await register(client)
    export_id = await requested_and_built(client, maker, settings, user, clock())
    resp = await download_export(client, user, export_id, **{"X-Device-ID": "another-device"})
    assert resp.status_code == 200


async def test_a_notice_is_mailed_once_per_new_request_and_carries_no_data(
    client: AsyncClient, clock: FakeClock
) -> None:
    user = await register(client)
    await create_medication(client, user, name=NEEDLE_NAME)
    first = await request_export(client, user)
    replay = await request_export(client, user)
    assert (first.status_code, replay.status_code) == (202, 200)
    assert replay.json()["id"] == first.json()["id"]
    mails = sent_to(client, user.email, "export_requested")
    assert len(mails) == 1  # the replay sent none
    assert mails[0].code is None
    assert NEEDLE_NAME not in repr(mails[0])


# --- cooldown ---------------------------------------------------------------------------------


async def test_a_new_request_within_the_cooldown_is_429_unless_the_last_was_downloaded(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
) -> None:
    user = await register(client)
    other_session = await second_session(client, user)
    export_id = await requested_and_built(client, maker, settings, user, clock())

    # Another session of the account is not a replay (it could not download): cooldown.
    clock.advance(seconds=600)
    refused = await request_export(client, other_session)
    assert refused.status_code == 429
    assert refused.json()["error"]["code"] == "export_rate_limited"
    assert 0 < int(refused.headers["retry-after"]) <= 3000

    assert (await download_export(client, user, export_id)).status_code == 200
    fresh = await request_export(client, other_session)  # downloaded rows do not count
    assert fresh.status_code == 202
    assert fresh.json()["id"] != export_id


async def test_after_the_cooldown_a_new_request_is_accepted(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
) -> None:
    user = await register(client)
    other_session = await second_session(client, user)
    await requested_and_built(client, maker, settings, user, clock())
    clock.advance(seconds=settings.export_cooldown_seconds + 1)
    assert (await request_export(client, other_session)).status_code == 202
