"""``/v1/me/export``: request, status, single download (Phase 5.5, ADR 0016 section 8)."""

from __future__ import annotations

import asyncio
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
from tests.grace_helpers import app_of, count, request_deletion, sent_to
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
    missing = await client.post("/v1/me/export", headers=user.headers)
    assert missing.status_code == 401
    assert missing.json()["error"]["code"] == "reauth_required"
    empty = await client.post("/v1/me/export", json={}, headers=user.headers)
    assert empty.json()["error"]["code"] == "reauth_required"
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
    responses = await asyncio.gather(*(download_export(client, user, export_id) for _ in range(5)))
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
