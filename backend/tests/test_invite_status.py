"""``GET /v1/invites/{id}`` (ADR 0020 section 2): the creator watches the QR code being used."""

from __future__ import annotations

import uuid
from typing import Any

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from tests.conftest import FakeClock
from tests.consent_pause_helpers import withdraw_health
from tests.helpers import (
    User,
    accept_invite,
    create_invite,
    create_managed_profile,
    register,
    token_of,
)


async def status_of(client: AsyncClient, user: User, invite_id: str) -> Any:
    return await client.get(f"/v1/invites/{invite_id}", headers=user.headers)


async def test_an_open_invite_reports_its_state_and_times_without_secrets(
    client: AsyncClient, clock: FakeClock
) -> None:
    owner = await register(client)
    invite = await create_invite(client, owner, role="editor")
    resp = await status_of(client, owner, invite["id"])
    assert resp.status_code == 200
    assert resp.json() == {
        "id": invite["id"],
        "role": "editor",
        "state": "open",
        "created_at": invite["created_at"],
        "expires_at": invite["expires_at"],
    }
    assert token_of(invite) not in resp.text


async def test_the_state_follows_the_lifecycle(client: AsyncClient, clock: FakeClock) -> None:
    owner, relative = await register(client), await register(client)
    consumed = await create_invite(client, owner)
    assert (await accept_invite(client, relative, token_of(consumed))).status_code == 201
    revoked = await create_invite(client, owner)
    await client.delete(
        f"/v1/profiles/{owner.self_profile_id}/invites/{revoked['id']}", headers=owner.headers
    )
    expiring = await create_invite(client, owner)
    clock.advance(seconds=901)
    states = {
        name: (await status_of(client, owner, invite["id"])).json()["state"]
        for name, invite in (("consumed", consumed), ("revoked", revoked), ("expired", expiring))
    }
    assert states == {"consumed": "consumed", "revoked": "revoked", "expired": "expired"}
    # The accepter is not named here: GET /v1/grants is where the creator sees who joined.
    assert relative.email not in (await status_of(client, owner, consumed["id"])).text


async def test_an_invite_on_a_deleted_profile_is_no_longer_open(client: AsyncClient) -> None:
    owner = await register(client)
    ward = await create_managed_profile(client, owner)
    invite = await create_invite(client, owner, ward, "guardian")
    assert (await client.delete(f"/v1/profiles/{ward}", headers=owner.headers)).status_code == 204
    assert (await status_of(client, owner, invite["id"])).json()["state"] == "revoked"


async def test_only_the_creator_sees_an_invite(client: AsyncClient) -> None:
    owner, relative, stranger = [await register(client) for _ in range(3)]
    invite = await create_invite(client, owner)
    assert (await accept_invite(client, relative, token_of(invite))).status_code == 201
    for user in (relative, stranger):  # the accepter learns nothing new here either
        resp = await status_of(client, user, invite["id"])
        assert (resp.status_code, resp.json()["error"]["code"]) == (404, "not_found")
    missing = await status_of(client, owner, str(uuid.uuid4()))
    assert missing.status_code == 404


async def test_status_needs_authentication_and_a_uuid(client: AsyncClient) -> None:
    owner = await register(client)
    invite = await create_invite(client, owner)
    assert (await client.get(f"/v1/invites/{invite['id']}")).status_code == 401
    assert (await status_of(client, owner, "not-a-uuid")).status_code == 422


async def test_polling_is_not_rate_limited(client: AsyncClient, settings: Settings) -> None:
    """The app polls every ~3 s while the code is shown: 15 minutes is ~300 reads."""
    owner = await register(client)
    invite = await create_invite(client, owner)
    for _ in range(3 * settings.rate_limit_auth_max_attempts):  # well past any user budget
        assert (await status_of(client, owner, invite["id"])).status_code == 200


async def test_a_paused_profile_takes_nobody_so_its_invite_is_not_open(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    invite = await create_invite(client, owner)
    await withdraw_health(engine, owner)
    assert (await status_of(client, owner, invite["id"])).json()["state"] == "revoked"
    resp = await accept_invite(client, relative, token_of(invite))
    assert (resp.status_code, resp.json()["error"]["code"]) == (404, "invite_invalid")
