"""Invites (ADR 0009): create, list, revoke, preview and accept, with the security properties."""

from __future__ import annotations

import hashlib
import re
import uuid
from datetime import datetime, timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from tests.conftest import FakeClock
from tests.helpers import (
    User,
    accept_invite,
    create_invite,
    create_managed_profile,
    link_accounts,
    register,
    token_of,
)

TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")  # secrets.token_urlsafe(32)


def parse_ts(value: str) -> datetime:
    return datetime.fromisoformat(value)


async def rows(engine: AsyncEngine, sql: str, **params: Any) -> list[Any]:
    async with engine.connect() as conn:
        return list((await conn.execute(text(sql), params)).all())


async def create_raw(
    client: AsyncClient, user: User, profile_id: str, body: dict[str, Any] | None = None
) -> Any:
    payload = {"id": str(uuid.uuid4()), "role": "viewer", "disclosure_version": 1}
    return await client.post(
        f"/v1/profiles/{profile_id}/invites", json=body or payload, headers=user.headers
    )


# --- create ----------------------------------------------------------------------------------


async def test_create_returns_the_link_once(
    client: AsyncClient, clock: FakeClock, disclosure_versions: list[int]
) -> None:
    owner = await register(client)
    invite_id = str(uuid.uuid4())
    resp = await client.post(
        f"/v1/profiles/{owner.self_profile_id}/invites",
        json={"id": invite_id, "role": "editor", "disclosure_version": 3},
        headers=owner.headers,
    )
    assert resp.status_code == 201
    body = resp.json()
    assert set(body) == {"id", "role", "expires_at", "url"}
    assert body["id"] == invite_id
    assert body["role"] == "editor"
    prefix = "https://links-ru.pillpal.invalid/i#"
    assert body["url"].startswith(prefix)
    assert TOKEN_RE.match(body["url"][len(prefix) :])
    assert parse_ts(body["expires_at"]) == clock.now + timedelta(days=7)


async def test_the_token_is_stored_only_as_a_hash(client: AsyncClient, engine: AsyncEngine) -> None:
    owner = await register(client)
    invite = await create_invite(client, owner)
    token = token_of(invite)
    [row] = await rows(engine, "SELECT token_hash FROM invites")
    assert row[0] == hashlib.sha256(token.encode()).hexdigest()
    leaks = await rows(engine, "SELECT 1 FROM invites i WHERE i::text LIKE :t", t=f"%{token}%")
    assert leaks == []


async def test_tokens_are_unique_and_never_returned_again(client: AsyncClient) -> None:
    owner = await register(client)
    first = await create_invite(client, owner)
    second = await create_invite(client, owner)
    assert token_of(first) != token_of(second)
    listed = await client.get(
        f"/v1/profiles/{owner.self_profile_id}/invites", headers=owner.headers
    )
    assert token_of(first) not in listed.text
    assert "url" not in listed.text
    assert "token" not in listed.text


async def test_guardian_invites_live_24_hours(client: AsyncClient, clock: FakeClock) -> None:
    owner = await register(client)
    ward = await create_managed_profile(client, owner)
    invite = await create_invite(client, owner, ward, "guardian")
    assert invite["role"] == "guardian"
    assert (
        invite["expires_at"].replace("Z", "+00:00") == (clock.now + timedelta(hours=24)).isoformat()
    )


async def test_guardian_invite_on_a_self_profile_is_422(client: AsyncClient) -> None:
    owner = await register(client)
    resp = await create_raw(
        client,
        owner,
        owner.self_profile_id,
        {"id": str(uuid.uuid4()), "role": "guardian", "disclosure_version": 1},
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "validation_error"


async def test_create_requires_authentication(client: AsyncClient) -> None:
    owner = await register(client)
    resp = await client.post(
        f"/v1/profiles/{owner.self_profile_id}/invites",
        json={"id": str(uuid.uuid4()), "role": "viewer", "disclosure_version": 1},
    )
    assert resp.status_code == 401


@pytest.mark.parametrize(
    "body",
    [
        {"role": "viewer", "disclosure_version": 1},
        {"id": "not-a-uuid", "role": "viewer", "disclosure_version": 1},
        {"id": str(uuid.uuid4()), "role": "owner", "disclosure_version": 1},
        {"id": str(uuid.uuid4()), "role": "viewer"},
        {"id": str(uuid.uuid4()), "role": "viewer", "disclosure_version": 0},
        {"id": str(uuid.uuid4()), "role": "viewer", "disclosure_version": "1"},
        {"id": str(uuid.uuid4()), "role": "viewer", "disclosure_version": 2},  # not a known screen
        {"id": str(uuid.uuid4()), "role": "viewer", "disclosure_version": 1, "ttl": 10},
    ],
)
async def test_create_validates_the_body(client: AsyncClient, body: dict[str, Any]) -> None:
    owner = await register(client)
    resp = await create_raw(client, owner, owner.self_profile_id, body)
    assert resp.status_code == 422


async def test_only_the_owner_can_create_invites(client: AsyncClient, engine: AsyncEngine) -> None:
    owner, stranger, guardian = [await register(client) for _ in range(3)]
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, guardian, "guardian", ward)
    for user, profile in [
        (stranger, owner.self_profile_id),
        (guardian, ward),  # guardians run the profile but do not manage links (ADR 0005 §2)
        (owner, str(uuid.uuid4())),
    ]:
        assert (await create_raw(client, user, profile)).status_code == 404
    assert (await rows(engine, "SELECT count(*) FROM invites WHERE role = 'viewer'"))[0][0] == 0


async def test_a_deleted_profile_takes_no_invites(client: AsyncClient) -> None:
    owner = await register(client)
    ward = await create_managed_profile(client, owner)
    await client.delete(f"/v1/profiles/{ward}", headers=owner.headers)
    assert (await create_raw(client, owner, ward)).status_code == 404


async def test_create_replay_is_a_conflict_and_makes_no_second_invite(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, other = await register(client), await register(client)
    body = {"id": str(uuid.uuid4()), "role": "viewer", "disclosure_version": 1}
    assert (await create_raw(client, owner, owner.self_profile_id, body)).status_code == 201
    replay = await create_raw(client, owner, owner.self_profile_id, body)
    assert replay.status_code == 409
    assert replay.json()["error"]["code"] == "already_exists"
    assert "url" not in replay.text
    # Ids are global: someone else's id gives the same answer and never overwrites.
    again = await create_raw(client, other, other.self_profile_id, body)
    assert again.status_code == 409
    assert (await rows(engine, "SELECT count(*) FROM invites"))[0][0] == 1


async def test_active_invites_per_profile_are_capped(
    client: AsyncClient, clock: FakeClock, settings: Settings
) -> None:
    owner = await register(client)
    created = [
        await create_invite(client, owner) for _ in range(settings.max_active_invites_per_profile)
    ]
    over = await create_raw(client, owner, owner.self_profile_id)
    assert over.status_code == 409
    assert over.json()["error"]["code"] == "too_many_invites"

    # A revoked invite frees its slot; so does an expired one.
    revoke = await client.delete(
        f"/v1/profiles/{owner.self_profile_id}/invites/{created[0]['id']}", headers=owner.headers
    )
    assert revoke.status_code == 204
    assert (await create_raw(client, owner, owner.self_profile_id)).status_code == 201
    assert (await create_raw(client, owner, owner.self_profile_id)).status_code == 409
    clock.advance(days=8)
    assert (await create_raw(client, owner, owner.self_profile_id)).status_code == 201


async def test_the_cap_is_per_profile_and_a_consumed_invite_frees_its_slot(
    client: AsyncClient, settings: Settings
) -> None:
    owner, relative = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    created = [
        await create_invite(client, owner) for _ in range(settings.max_active_invites_per_profile)
    ]
    assert (await create_raw(client, owner, owner.self_profile_id)).status_code == 409
    assert (await create_raw(client, owner, ward)).status_code == 201  # another profile
    assert (await accept_invite(client, relative, token_of(created[0]))).status_code == 201
    assert (await create_raw(client, owner, owner.self_profile_id)).status_code == 201


# --- list and revoke --------------------------------------------------------------------------


async def test_list_shows_active_invites_without_secrets(
    client: AsyncClient, clock: FakeClock
) -> None:
    owner, relative = await register(client), await register(client)
    open_invite = await create_invite(client, owner, role="editor")
    revoked = await create_invite(client, owner)
    used = await create_invite(client, owner)
    old = await create_invite(client, owner)
    base = f"/v1/profiles/{owner.self_profile_id}/invites"
    await client.delete(f"{base}/{revoked['id']}", headers=owner.headers)
    assert (await accept_invite(client, relative, token_of(used))).status_code == 201
    clock.advance(days=8)
    fresh = await create_invite(client, owner)
    resp = await client.get(base, headers=owner.headers)
    assert resp.status_code == 200
    items = resp.json()["items"]
    assert {i["id"] for i in items} == {fresh["id"]}
    assert open_invite["id"] not in resp.text
    assert old["id"] not in resp.text
    assert set(items[0]) == {"id", "role", "created_at", "expires_at"}


async def test_list_and_revoke_are_scoped_to_the_owner(client: AsyncClient) -> None:
    owner, stranger = await register(client), await register(client)
    invite = await create_invite(client, owner)
    base = f"/v1/profiles/{owner.self_profile_id}/invites"
    assert (await client.get(base)).status_code == 401
    assert (await client.delete(f"{base}/{invite['id']}")).status_code == 401
    assert (await client.get(base, headers=stranger.headers)).status_code == 404
    assert (
        await client.delete(f"{base}/{invite['id']}", headers=stranger.headers)
    ).status_code == 404
    other_base = f"/v1/profiles/{stranger.self_profile_id}/invites"
    # The invite id under another profile is as good as missing.
    assert (
        await client.delete(f"{other_base}/{invite['id']}", headers=stranger.headers)
    ).status_code == 404
    assert (await client.delete(f"{base}/{uuid.uuid4()}", headers=owner.headers)).status_code == 404
    still = await client.post(
        "/v1/invites/preview", json={"token": token_of(invite)}, headers=stranger.headers
    )
    assert still.status_code == 200


async def test_revoking_kills_the_link_and_is_idempotent(client: AsyncClient) -> None:
    owner, relative = await register(client), await register(client)
    invite = await create_invite(client, owner)
    url = f"/v1/profiles/{owner.self_profile_id}/invites/{invite['id']}"
    assert (await client.delete(url, headers=owner.headers)).status_code == 204
    assert (await client.delete(url, headers=owner.headers)).status_code == 204  # retry
    resp = await accept_invite(client, relative, token_of(invite))
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "invite_invalid"


async def test_a_consumed_invite_cannot_be_revoked(client: AsyncClient) -> None:
    owner, relative = await register(client), await register(client)
    invite = await create_invite(client, owner)
    await accept_invite(client, relative, token_of(invite))
    resp = await client.delete(
        f"/v1/profiles/{owner.self_profile_id}/invites/{invite['id']}", headers=owner.headers
    )
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "invite_used"


async def test_invite_creation_is_rate_limited(client: AsyncClient) -> None:
    owner = await register(client)
    for _ in range(20):  # tests.conftest.make_settings
        assert (await create_raw(client, owner, owner.self_profile_id)).status_code in {201, 409}
    resp = await create_raw(client, owner, owner.self_profile_id)
    assert resp.status_code == 429
