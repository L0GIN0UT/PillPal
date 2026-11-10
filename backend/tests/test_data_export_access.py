"""``/v1/me/export``: who may download, expiry, encryption at rest, limits, deletion."""

from __future__ import annotations

import asyncio
import uuid

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
from tests.grace_helpers import app_of, count, request_deletion
from tests.helpers import create_medication, register

pytestmark = pytest.mark.usefixtures("export_on")

NEEDLE_NAME = "Needle-Аспирин-7731"


# --- who may download -------------------------------------------------------------------------


async def test_another_session_of_the_account_gets_404_and_the_owner_session_still_works(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
) -> None:
    user = await register(client)
    other_session = await second_session(client, user)
    export_id = await requested_and_built(client, maker, settings, user, clock())

    blocked = await download_export(client, other_session, export_id)
    assert blocked.status_code == 404
    assert blocked.json()["error"]["code"] == "not_found"
    assert (await download_export(client, user, export_id)).status_code == 200


async def test_a_signed_out_session_cannot_download_with_its_access_token(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
) -> None:
    user = await register(client)
    export_id = await requested_and_built(client, maker, settings, user, clock())
    out = await client.post("/v1/auth/logout", json={"refresh_token": user.refresh_token})
    assert out.status_code == 204
    assert (await download_export(client, user, export_id)).status_code == 404


async def test_another_account_sees_404_on_status_and_download(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
) -> None:
    owner, stranger = await register(client), await register(client)
    export_id = await requested_and_built(client, maker, settings, owner, clock())
    assert (await export_status(client, stranger, export_id)).status_code == 404
    assert (await download_export(client, stranger, export_id)).status_code == 404
    assert (await export_status(client, stranger, str(uuid.uuid4()))).status_code == 404
    assert (await export_status(client, owner, export_id)).status_code == 200  # untouched


async def test_a_malformed_id_is_422(client: AsyncClient) -> None:
    user = await register(client)
    assert (await export_status(client, user, "not-a-uuid")).status_code == 422
    assert (await download_export(client, user, "not-a-uuid")).status_code == 422


async def test_concurrent_downloads_have_one_winner(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
) -> None:
    user = await register(client)
    export_id = await requested_and_built(client, maker, settings, user, clock())
    app = app_of(client)
    live = app.state.export_download_slots
    app.state.export_download_slots = asyncio.Semaphore(10)  # the cap is tested apart
    try:
        responses = await asyncio.gather(
            *(download_export(client, user, export_id) for _ in range(5))
        )
    finally:
        app.state.export_download_slots = live
    assert sorted(r.status_code for r in responses) == [200, 410, 410, 410, 410]


# --- expiry, failure states -------------------------------------------------------------------


async def test_an_unfetched_export_expires_after_the_ttl(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
) -> None:
    user = await register(client)
    export_id = await requested_and_built(client, maker, settings, user, clock())
    clock.advance(hours=settings.export_ttl_hours, seconds=1)
    # Past expiry, before the cron: reads as expired, and the download is refused.
    assert (await export_status(client, user, export_id)).json()["status"] == "expired"
    gone = await download_export(client, user, export_id)
    assert (gone.status_code, gone.json()["error"]["code"]) == (410, "export_gone")
    await run_builder(maker, settings, clock())
    row = await export_row(engine, export_id)
    assert (row.status, row.archive) == ("expired", None)


async def test_a_failed_export_says_so(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
) -> None:
    user = await register(client)
    export_id = (await request_export(client, user)).json()["id"]
    async with engine.begin() as conn:
        await conn.execute(
            text("UPDATE data_exports SET status='failed', error_code='export_build_failed'")
        )
    resp = await download_export(client, user, export_id)
    assert (resp.status_code, resp.json()["error"]["code"]) == (409, "export_failed")
    status = (await export_status(client, user, export_id)).json()
    assert (status["status"], status["error_code"]) == ("failed", "export_build_failed")


# --- encryption at rest -----------------------------------------------------------------------


async def test_the_stored_archive_is_ciphertext_without_the_data(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
) -> None:
    user = await register(client)
    await create_medication(client, user, name=NEEDLE_NAME)
    export_id = await requested_and_built(client, maker, settings, user, clock())
    blob = bytes((await export_row(engine, export_id)).archive)
    assert blob[0] == settings.data_encryption_key_id
    assert not blob[1:].startswith(b"PK")  # not a zip
    for needle in (NEEDLE_NAME, user.email, "Aspirin", "medications", "manifest"):
        assert needle.encode() not in blob
    got = await download_export(client, user, export_id)
    assert NEEDLE_NAME in zip_members(got.content)["tables/medications.json"].decode()


async def test_a_blob_moved_to_another_export_does_not_open(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
) -> None:
    alice, bob = await register(client), await register(client)
    alice_export = await requested_and_built(client, maker, settings, alice, clock())
    bob_export = (await request_export(client, bob)).json()["id"]
    await run_builder(maker, settings, clock())
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "UPDATE data_exports SET archive = (SELECT archive FROM data_exports WHERE id=:a)"
                " WHERE id = :b"
            ),
            {"a": uuid.UUID(alice_export), "b": uuid.UUID(bob_export)},
        )
    resp = await download_export(client, bob, bob_export)
    assert resp.status_code == 500
    assert resp.json()["error"]["code"] == "export_unavailable"


async def test_rotation_new_exports_use_the_current_key_and_old_ones_still_open(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    old_user, new_user = await register(client), await register(client)
    old_export = await requested_and_built(client, maker, settings, old_user, clock())
    monkeypatch.setattr(settings, "data_encryption_key_id", 2)
    new_export = await requested_and_built(client, maker, settings, new_user, clock())
    assert bytes((await export_row(engine, old_export)).archive)[0] == 1
    assert bytes((await export_row(engine, new_export)).archive)[0] == 2
    assert (await download_export(client, old_user, old_export)).status_code == 200
    assert (await download_export(client, new_user, new_export)).status_code == 200


# --- rate limits ------------------------------------------------------------------------------


async def test_status_polling_is_limited_per_user(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    user = await register(client)
    monkeypatch.setattr(settings, "export_status_rate_limit", 2)
    some_id = str(uuid.uuid4())
    codes = [(await export_status(client, user, some_id)).status_code for _ in range(3)]
    assert codes == [404, 404, 429]
    other = await register(client)
    assert (await export_status(client, other, some_id)).status_code == 404  # per user


async def test_download_attempts_are_limited_per_user(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    user = await register(client)
    monkeypatch.setattr(settings, "export_download_rate_limit", 2)
    some_id = str(uuid.uuid4())
    codes = [(await download_export(client, user, some_id)).status_code for _ in range(3)]
    assert codes == [404, 404, 429]


# --- deletion ---------------------------------------------------------------------------------


async def test_a_deletion_request_deletes_the_accounts_exports(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    clock: FakeClock,
    engine: AsyncEngine,
) -> None:
    user, bystander = await register(client), await register(client)
    await requested_and_built(client, maker, settings, user, clock())
    await requested_and_built(client, maker, settings, bystander, clock())
    assert await count(engine, "data_exports") == 2
    assert (await request_deletion(client, user)).status_code == 204
    assert await count(engine, "data_exports", "user_id = :u", u=uuid.UUID(user.id)) == 0
    assert await count(engine, "data_exports") == 1  # the bystander's stays
