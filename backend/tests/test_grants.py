"""Grants (ADR 0005 §3): listing, field-level PATCH, revoke and leave."""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from tests.helpers import (
    User,
    accept_invite,
    create_invite,
    create_managed_profile,
    link_accounts,
    register,
    token_of,
)


async def grants_of(client: AsyncClient, user: User) -> dict[str, Any]:
    resp = await client.get("/v1/grants", headers=user.headers)
    assert resp.status_code == 200, resp.text
    return dict(resp.json())


async def patch(client: AsyncClient, user: User, grant_id: str, body: dict[str, Any]) -> Any:
    return await client.patch(f"/v1/grants/{grant_id}", json=body, headers=user.headers)


async def stored(engine: AsyncEngine, grant_id: str) -> tuple[Any, ...]:
    async with engine.connect() as conn:
        row = (
            await conn.execute(
                text("SELECT role, notify_missed FROM profile_grants WHERE id = :g"),
                {"g": uuid.UUID(grant_id)},
            )
        ).one()
    return tuple(row)


# --- GET /v1/grants -------------------------------------------------------------------------


async def test_both_sides_see_the_link(client: AsyncClient) -> None:
    owner, relative = await register(client), await register(client)
    await client.patch(
        f"/v1/profiles/{relative.self_profile_id}",
        json={"display_name": "Synthetic Relative"},
        headers=relative.headers,
    )
    await client.patch(
        f"/v1/profiles/{owner.self_profile_id}",
        json={"display_name": "Synthetic Owner"},
        headers=owner.headers,
    )
    invite = await create_invite(client, owner, role="editor", disclosure_version=4)
    grant = (await accept_invite(client, relative, token_of(invite))).json()

    outgoing = (await grants_of(client, owner))["outgoing"]
    assert outgoing == [
        {
            "id": grant["id"],
            "profile_id": owner.self_profile_id,
            "profile_display_name": "Synthetic Owner",
            "profile_kind": "self",
            "grantee_display_name": "Synthetic Relative",
            "role": "editor",
            "active": True,
            "disclosure_version": 4,
            "created_at": grant["created_at"],
        }
    ]
    incoming = (await grants_of(client, relative))["incoming"]
    assert incoming == [
        {
            "id": grant["id"],
            "profile_id": owner.self_profile_id,
            "profile_display_name": "Synthetic Owner",
            "profile_kind": "self",
            "owner_display_name": "Synthetic Owner",
            "role": "editor",
            "notify_missed": True,
            "created_at": grant["created_at"],
        }
    ]
    assert (await grants_of(client, owner))["incoming"] == []
    assert (await grants_of(client, relative))["outgoing"] == []


async def test_a_stranger_sees_nothing_and_anonymous_is_refused(client: AsyncClient) -> None:
    owner, relative, stranger = [await register(client) for _ in range(3)]
    await link_accounts(client, owner, relative)
    assert await grants_of(client, stranger) == {"outgoing": [], "incoming": []}
    assert (await client.get("/v1/grants")).status_code == 401


async def test_grants_of_a_deleted_profile_are_not_listed(client: AsyncClient) -> None:
    owner, relative = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, relative, "guardian", ward)
    await client.delete(f"/v1/profiles/{ward}", headers=owner.headers)
    assert (await grants_of(client, owner))["outgoing"] == []
    assert (await grants_of(client, relative))["incoming"] == []


async def test_the_list_is_capped(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    monkeypatch.setattr(settings, "grants_list_limit", 2)
    owner = await register(client)
    for _ in range(3):
        await link_accounts(client, owner, await register(client))
    assert len((await grants_of(client, owner))["outgoing"]) == 2


# --- PATCH -------------------------------------------------------------------------------------


async def test_the_owner_changes_the_role(client: AsyncClient, engine: AsyncEngine) -> None:
    owner, relative = await register(client), await register(client)
    grant = await link_accounts(client, owner, relative, "viewer")
    resp = await patch(client, owner, grant["id"], {"role": "editor"})
    assert resp.status_code == 200
    assert resp.json()["role"] == "editor"
    assert "notify_missed" not in resp.json()  # the grantee's choice stays private
    assert (await stored(engine, grant["id"]))[0] == "editor"
    assert (await grants_of(client, relative))["incoming"][0]["role"] == "editor"
    assert (
        await patch(client, owner, grant["id"], {"role": "editor"})
    ).status_code == 200  # replay


async def test_guardian_role_needs_a_managed_profile(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    own = await link_accounts(client, owner, relative, "viewer")
    resp = await patch(client, owner, own["id"], {"role": "guardian"})
    assert resp.status_code == 422
    assert (await stored(engine, own["id"]))[0] == "viewer"

    ward = await create_managed_profile(client, owner)
    managed = await link_accounts(client, owner, relative, "viewer", ward)
    resp = await patch(client, owner, managed["id"], {"role": "guardian"})
    assert (resp.status_code, resp.json()["role"]) == (200, "guardian")


async def test_the_grantee_changes_only_notify_missed(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    grant = await link_accounts(client, owner, relative, "viewer")
    resp = await patch(client, relative, grant["id"], {"notify_missed": False})
    assert resp.status_code == 200
    assert resp.json()["notify_missed"] is False
    assert (await grants_of(client, relative))["incoming"][0]["notify_missed"] is False
    assert (await stored(engine, grant["id"])) == ("viewer", False)
    outgoing = (await grants_of(client, owner))["outgoing"][0]
    assert "notify_missed" not in outgoing


@pytest.mark.parametrize("who", ["owner", "grantee"])
@pytest.mark.parametrize(
    "body",
    [
        {"role": "editor", "notify_missed": False},  # mixed: never applied partially
        {},
        {"role": None},
        {"notify_missed": None},
        {"role": "owner"},
        {"role": "admin"},
        {"notify_missed": "no"},
        {"notify_missed": 0},
        {"role": "editor", "extra": 1},
    ],
)
async def test_invalid_and_mixed_bodies_change_nothing(
    client: AsyncClient, engine: AsyncEngine, who: str, body: dict[str, Any]
) -> None:
    owner, relative = await register(client), await register(client)
    grant = await link_accounts(client, owner, relative, "viewer")
    caller = owner if who == "owner" else relative
    resp = await patch(client, caller, grant["id"], body)
    assert resp.status_code == 422
    assert await stored(engine, grant["id"]) == ("viewer", True)


async def test_each_party_may_only_set_its_own_field(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    grant = await link_accounts(client, owner, relative, "viewer")
    assert (await patch(client, owner, grant["id"], {"notify_missed": False})).status_code == 422
    assert (await patch(client, relative, grant["id"], {"role": "editor"})).status_code == 422
    assert await stored(engine, grant["id"]) == ("viewer", True)


async def test_patch_is_404_for_everyone_else(client: AsyncClient, engine: AsyncEngine) -> None:
    owner, relative, stranger, guardian = [await register(client) for _ in range(4)]
    ward = await create_managed_profile(client, owner)
    grant = await link_accounts(client, owner, relative, "viewer", ward)
    await link_accounts(client, owner, guardian, "guardian", ward)
    for caller in (stranger, guardian):  # co-guardians do not manage other grants
        assert (await patch(client, caller, grant["id"], {"role": "editor"})).status_code == 404
        assert (
            await patch(client, caller, grant["id"], {"notify_missed": False})
        ).status_code == 404
    assert (await patch(client, owner, str(uuid.uuid4()), {"role": "editor"})).status_code == 404
    unauthenticated = await client.patch(f"/v1/grants/{grant['id']}", json={"role": "editor"})
    assert unauthenticated.status_code == 401
    assert await stored(engine, grant["id"]) == ("viewer", True)


async def test_patch_on_a_deleted_profile_is_404(client: AsyncClient) -> None:
    owner, relative = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    grant = await link_accounts(client, owner, relative, "viewer", ward)
    await client.delete(f"/v1/profiles/{ward}", headers=owner.headers)
    assert (await patch(client, owner, grant["id"], {"role": "editor"})).status_code == 404
    assert (await patch(client, relative, grant["id"], {"notify_missed": False})).status_code == 404


# --- DELETE ------------------------------------------------------------------------------------


@pytest.mark.parametrize("who", ["owner", "grantee"])
async def test_either_party_can_end_the_link(client: AsyncClient, who: str) -> None:
    owner, relative = await register(client), await register(client)
    grant = await link_accounts(client, owner, relative)
    caller = owner if who == "owner" else relative
    assert (
        await client.delete(f"/v1/grants/{grant['id']}", headers=caller.headers)
    ).status_code == 204
    assert (await grants_of(client, owner))["outgoing"] == []
    assert (await grants_of(client, relative))["incoming"] == []
    # No history is kept: a retry finds nothing, and the pair can be linked again.
    assert (
        await client.delete(f"/v1/grants/{grant['id']}", headers=caller.headers)
    ).status_code == 404
    assert (await link_accounts(client, owner, relative))["role"] == "viewer"


async def test_delete_is_404_for_everyone_else(client: AsyncClient) -> None:
    owner, relative, stranger, guardian = [await register(client) for _ in range(4)]
    ward = await create_managed_profile(client, owner)
    grant = await link_accounts(client, owner, relative, "viewer", ward)
    await link_accounts(client, owner, guardian, "guardian", ward)
    url = f"/v1/grants/{grant['id']}"
    assert (await client.delete(url, headers=stranger.headers)).status_code == 404
    assert (await client.delete(url, headers=guardian.headers)).status_code == 404
    assert (
        await client.delete(f"/v1/grants/{uuid.uuid4()}", headers=owner.headers)
    ).status_code == 404
    assert (await client.delete(url)).status_code == 401
    assert len((await grants_of(client, owner))["outgoing"]) == 2


async def test_a_guardian_can_leave(client: AsyncClient) -> None:
    owner, guardian = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    grant = await link_accounts(client, owner, guardian, "guardian", ward)
    resp = await client.delete(f"/v1/grants/{grant['id']}", headers=guardian.headers)
    assert resp.status_code == 204
