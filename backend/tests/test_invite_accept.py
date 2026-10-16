"""Invite preview and accept (ADR 0009 §4): errors, replays, races, limits."""

from __future__ import annotations

import asyncio
import uuid
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from app.services import invites as invites_service
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
from tests.test_invites import rows

# --- preview ---------------------------------------------------------------------------------


async def preview(client: AsyncClient, user: User, token: str) -> Any:
    return await client.post("/v1/invites/preview", json={"token": token}, headers=user.headers)


async def test_preview_shows_who_invites_to_what_and_consumes_nothing(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    await client.patch(
        f"/v1/profiles/{owner.self_profile_id}",
        json={"display_name": "Synthetic Owner"},
        headers=owner.headers,
    )
    ward = await create_managed_profile(client, owner, "Synthetic Ward")
    invite = await create_invite(client, owner, ward, "guardian")
    resp = await preview(client, relative, token_of(invite))
    assert resp.status_code == 200
    body = resp.json()
    assert body == {
        "inviter_display_name": "Synthetic Owner",
        "profile_display_name": "Synthetic Ward",
        "profile_kind": "managed",
        "role": "guardian",
        "expires_at": invite["expires_at"],
    }
    assert owner.email not in resp.text
    assert (await rows(engine, "SELECT count(*) FROM profile_grants"))[0][0] == 0
    assert (await accept_invite(client, relative, token_of(invite))).status_code == 201


async def test_preview_errors_are_distinct(client: AsyncClient, clock: FakeClock) -> None:
    owner, relative = await register(client), await register(client)
    unknown = await preview(client, relative, "x" * 43)
    assert (unknown.status_code, unknown.json()["error"]["code"]) == (404, "invite_invalid")

    revoked = await create_invite(client, owner)
    await client.delete(
        f"/v1/profiles/{owner.self_profile_id}/invites/{revoked['id']}", headers=owner.headers
    )
    assert (await preview(client, relative, token_of(revoked))).json()["error"][
        "code"
    ] == "invite_invalid"

    used = await create_invite(client, owner)
    await accept_invite(client, relative, token_of(used))
    resp = await preview(client, relative, token_of(used))  # the consumer itself
    assert (resp.status_code, resp.json()["error"]["code"]) == (409, "invite_used")
    third = await register(client)  # any other holder learns nothing about its history
    resp = await preview(client, third, token_of(used))
    assert (resp.status_code, resp.json()["error"]["code"]) == (404, "invite_invalid")

    own = await create_invite(client, owner)
    resp = await preview(client, owner, token_of(own))
    assert (resp.status_code, resp.json()["error"]["code"]) == (409, "invite_own_profile")

    old = await create_invite(client, owner)
    clock.advance(days=7, seconds=1)
    resp = await preview(client, relative, token_of(old))
    assert (resp.status_code, resp.json()["error"]["code"]) == (410, "invite_expired")


async def test_preview_input_and_authentication(client: AsyncClient) -> None:
    user = await register(client)
    assert (await client.post("/v1/invites/preview", json={"token": "x"})).status_code == 401
    for body in ({}, {"token": ""}, {"token": "x" * 300}, {"token": "x", "extra": 1}):
        resp = await client.post("/v1/invites/preview", json=body, headers=user.headers)
        assert resp.status_code == 422


async def test_preview_and_accept_are_rate_limited(client: AsyncClient) -> None:
    user = await register(client)
    for _ in range(20):  # tests.conftest.make_settings
        assert (await preview(client, user, "x" * 43)).status_code == 404
    assert (await preview(client, user, "x" * 43)).status_code == 429
    # The two endpoints have separate budgets.
    assert (await accept_invite(client, user, "x" * 43)).status_code == 404
    for _ in range(19):
        await accept_invite(client, user, "x" * 43)
    resp = await accept_invite(client, user, "x" * 43)
    assert resp.status_code == 429
    assert resp.json()["error"]["code"] == "rate_limited"


# --- accept ----------------------------------------------------------------------------------


async def test_accept_creates_the_grant_and_consumes_the_invite(
    client: AsyncClient, engine: AsyncEngine, disclosure_versions: list[int]
) -> None:
    owner, relative = await register(client), await register(client)
    invite = await create_invite(client, owner, role="editor", disclosure_version=7)
    resp = await accept_invite(client, relative, token_of(invite))
    assert resp.status_code == 201
    grant = resp.json()
    assert grant["profile_id"] == owner.self_profile_id
    assert (grant["role"], grant["notify_missed"]) == ("editor", True)
    [row] = await rows(
        engine,
        "SELECT grantee_user_id::text, role, disclosure_version, invite_id::text, "
        "(SELECT consumed_by_user_id::text FROM invites), "
        "(SELECT consumed_at IS NOT NULL FROM invites) FROM profile_grants",
    )
    assert tuple(row) == (relative.id, "editor", 7, invite["id"], relative.id, True)


async def test_guardian_accept_gives_a_guardian_grant(client: AsyncClient) -> None:
    owner, relative = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    grant = await link_accounts(client, owner, relative, "guardian", ward)
    assert (grant["role"], grant["profile_id"], grant["profile_kind"]) == (
        "guardian",
        ward,
        "managed",
    )


async def test_accept_replay_by_the_same_user_returns_the_same_grant(
    client: AsyncClient, engine: AsyncEngine, monkeypatch: pytest.MonkeyPatch
) -> None:
    calls: list[Any] = []

    async def record(*args: Any, **kwargs: Any) -> None:
        calls.append((args, kwargs))

    monkeypatch.setattr(invites_service, "enqueue_link_accepted", record)
    owner, relative = await register(client), await register(client)
    invite = await create_invite(client, owner)
    first = await accept_invite(client, relative, token_of(invite))
    replay = await accept_invite(client, relative, token_of(invite))
    assert (first.status_code, replay.status_code) == (201, 200)
    assert first.json() == replay.json()
    assert (await rows(engine, "SELECT count(*) FROM profile_grants"))[0][0] == 1
    assert len(calls) == 1  # the owner is told about a link once


async def test_accept_revoke_accept_never_recreates_the_grant(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    invite = await create_invite(client, owner)
    grant = (await accept_invite(client, relative, token_of(invite))).json()
    revoke = await client.delete(f"/v1/grants/{grant['id']}", headers=owner.headers)
    assert revoke.status_code == 204
    again = await accept_invite(client, relative, token_of(invite))
    assert again.status_code == 409
    assert again.json()["error"]["code"] == "invite_used"
    assert (await rows(engine, "SELECT count(*) FROM profile_grants"))[0][0] == 0


async def test_leaving_then_accepting_the_old_link_is_invite_used(client: AsyncClient) -> None:
    owner, relative = await register(client), await register(client)
    invite = await create_invite(client, owner)
    grant = (await accept_invite(client, relative, token_of(invite))).json()
    assert (
        await client.delete(f"/v1/grants/{grant['id']}", headers=relative.headers)
    ).status_code == 204
    assert (await accept_invite(client, relative, token_of(invite))).json()["error"][
        "code"
    ] == "invite_used"


async def test_someone_else_cannot_use_a_consumed_invite(client: AsyncClient) -> None:
    owner, first, second = [await register(client) for _ in range(3)]
    invite = await create_invite(client, owner)
    await accept_invite(client, first, token_of(invite))
    resp = await accept_invite(client, second, token_of(invite))
    assert (resp.status_code, resp.json()["error"]["code"]) == (409, "invite_used")


async def test_replay_after_the_replay_window_is_invite_used(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    """Retention clears the accepter's id after the window (3.3b); the grant stays."""
    owner, relative = await register(client), await register(client)
    invite = await create_invite(client, owner)
    await accept_invite(client, relative, token_of(invite))
    async with engine.begin() as conn:
        await conn.execute(text("UPDATE invites SET consumed_by_user_id = NULL"))
    resp = await accept_invite(client, relative, token_of(invite))
    assert (resp.status_code, resp.json()["error"]["code"]) == (409, "invite_used")
    assert (await rows(engine, "SELECT count(*) FROM profile_grants"))[0][0] == 1


async def test_accept_errors(client: AsyncClient, clock: FakeClock, engine: AsyncEngine) -> None:
    owner, relative = await register(client), await register(client)
    unknown = await accept_invite(client, relative, "y" * 43)
    assert (unknown.status_code, unknown.json()["error"]["code"]) == (404, "invite_invalid")

    own = await create_invite(client, owner)
    resp = await accept_invite(client, owner, token_of(own))
    assert (resp.status_code, resp.json()["error"]["code"]) == (409, "invite_own_profile")
    consumed = await rows(engine, "SELECT consumed_at FROM invites WHERE id = :i", i=own["id"])
    assert consumed[0][0] is None  # the owner's slip does not burn the link
    assert (await accept_invite(client, relative, token_of(own))).status_code == 201

    old = await create_invite(client, owner)
    clock.advance(days=7, seconds=1)
    resp = await accept_invite(client, await register(client), token_of(old))
    assert (resp.status_code, resp.json()["error"]["code"]) == (410, "invite_expired")


async def test_accept_input_and_authentication(client: AsyncClient) -> None:
    user = await register(client)
    assert (await client.post("/v1/invites/accept", json={"token": "x"})).status_code == 401
    for body in ({}, {"token": ""}, {"token": "x", "role": "guardian"}):
        resp = await client.post("/v1/invites/accept", json=body, headers=user.headers)
        assert resp.status_code == 422


async def test_already_linked_does_not_consume_the_invite(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative, other = [await register(client) for _ in range(3)]
    await link_accounts(client, owner, relative, "viewer")
    second = await create_invite(client, owner, role="editor")
    resp = await accept_invite(client, relative, token_of(second))
    assert (resp.status_code, resp.json()["error"]["code"]) == (409, "already_linked")
    [row] = await rows(
        engine, "SELECT consumed_at, consumed_by_user_id FROM invites WHERE id = :i", i=second["id"]
    )
    assert tuple(row) == (None, None)
    # The link still works for somebody else, and the existing grant is untouched.
    assert (await accept_invite(client, other, token_of(second))).status_code == 201
    [grant_role] = await rows(
        engine,
        "SELECT role FROM profile_grants WHERE grantee_user_id = :u",
        u=uuid.UUID(relative.id),
    )
    assert grant_role[0] == "viewer"


async def test_concurrent_double_accept_by_two_users_makes_one_grant(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, first, second = [await register(client) for _ in range(3)]
    invite = await create_invite(client, owner)
    token = token_of(invite)
    results = await asyncio.gather(
        accept_invite(client, first, token), accept_invite(client, second, token)
    )
    assert sorted(r.status_code for r in results) == [201, 409]
    loser = next(r for r in results if r.status_code == 409)
    assert loser.json()["error"]["code"] == "invite_used"
    assert (await rows(engine, "SELECT count(*) FROM profile_grants"))[0][0] == 1


async def test_concurrent_double_accept_by_one_user_is_a_replay(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    token = token_of(await create_invite(client, owner))
    results = await asyncio.gather(*[accept_invite(client, relative, token) for _ in range(3)])
    assert sorted(r.status_code for r in results) == [200, 200, 201]
    assert len({r.json()["id"] for r in results}) == 1
    assert (await rows(engine, "SELECT count(*) FROM profile_grants"))[0][0] == 1


async def test_an_invite_on_a_deleted_profile_is_invalid(client: AsyncClient) -> None:
    owner, relative = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    invite = await create_invite(client, owner, ward)
    await client.delete(f"/v1/profiles/{ward}", headers=owner.headers)
    resp = await accept_invite(client, relative, token_of(invite))
    assert (resp.status_code, resp.json()["error"]["code"]) == (404, "invite_invalid")
    assert (await preview(client, relative, token_of(invite))).status_code == 404


async def test_too_many_access_scopes(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    monkeypatch.setattr(settings, "max_access_scopes_per_user", 2)
    owner, relative = await register(client), await register(client)
    await link_accounts(client, owner, relative)  # own self profile + this one = 2
    third = await register(client)
    resp = await accept_invite(client, relative, token_of(await create_invite(client, third)))
    assert (resp.status_code, resp.json()["error"]["code"]) == (409, "too_many_scopes")


async def test_tokens_never_reach_the_logs(
    client: AsyncClient, capsys: pytest.CaptureFixture[str]
) -> None:
    owner, relative = await register(client), await register(client)
    token = token_of(await create_invite(client, owner))
    await preview(client, relative, token)
    await accept_invite(client, relative, token)
    await accept_invite(client, relative, token)
    out = capsys.readouterr()
    assert token not in out.out + out.err


async def test_two_invites_of_one_owner_accepted_at_once_make_one_grant(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    first = token_of(await create_invite(client, owner))
    second = token_of(await create_invite(client, owner, role="editor"))
    results = await asyncio.gather(
        accept_invite(client, relative, first), accept_invite(client, relative, second)
    )
    assert sorted(r.status_code for r in results) == [201, 409]
    loser = next(r for r in results if r.status_code == 409)
    assert loser.json()["error"]["code"] == "already_linked"
    assert (await rows(engine, "SELECT count(*) FROM profile_grants"))[0][0] == 1
    # The losing link was not consumed.
    assert (await rows(engine, "SELECT count(*) FROM invites WHERE consumed_at IS NULL"))[0][0] == 1


async def test_concurrent_accepts_cannot_exceed_the_scope_limit(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    monkeypatch.setattr(settings, "max_access_scopes_per_user", 2)  # own profile + one
    first, second, relative = [await register(client) for _ in range(3)]
    tokens = [token_of(await create_invite(client, o)) for o in (first, second)]
    results = await asyncio.gather(*[accept_invite(client, relative, t) for t in tokens])
    assert sorted(r.status_code for r in results) == [201, 409]
    loser = next(r for r in results if r.status_code == 409)
    assert loser.json()["error"]["code"] == "too_many_scopes"
