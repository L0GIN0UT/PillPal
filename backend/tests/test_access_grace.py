"""Relatives lose access while an account is pending deletion and regain it on restore.

ADR 0010 §1 and ADR 0005 §3: a grant is *active* only while neither its grantee nor the
profile's owner is pending. Nothing is stored on the grant; the predicate is in every query.
"""

from __future__ import annotations

import uuid
from typing import Any

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from app.services import access
from tests.grace_helpers import delete_and_restore, request_deletion
from tests.helpers import create_medication, create_schedule, link_accounts, register
from tests.sync_helpers import scoped_pull, sync_all
from tests.test_access import role_of, visible


async def outgoing(client: AsyncClient, owner: Any) -> list[dict[str, Any]]:
    resp = await client.get("/v1/grants", headers=owner.headers)
    assert resp.status_code == 200
    return list(resp.json()["outgoing"])


async def incoming(client: AsyncClient, user: Any) -> list[dict[str, Any]]:
    return list((await client.get("/v1/grants", headers=user.headers)).json()["incoming"])


async def test_relatives_lose_access_at_the_request_and_regain_it_on_restore(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, viewer, editor = [await register(client) for _ in range(3)]
    medication = await create_medication(client, owner, name="Synthetic Tablet")
    await create_schedule(client, owner, medication["id"])
    await link_accounts(client, owner, viewer, "viewer")
    await link_accounts(client, owner, editor, "editor")
    before = await sync_all(client, viewer, {viewer.self_profile_id: 0})
    assert owner.self_profile_id in before.scopes

    assert (await request_deletion(client, owner)).status_code == 204

    for relative in (viewer, editor):
        assert await incoming(client, relative) == []
        assert await role_of(engine, relative, owner.self_profile_id) is None
        assert owner.self_profile_id not in await visible(engine, relative)
    page = await scoped_pull(
        client,
        viewer,
        {viewer.self_profile_id: 0, owner.self_profile_id: before.cursors[owner.self_profile_id]},
    )
    assert owner.self_profile_id in page["revoked"]
    assert owner.self_profile_id not in {s["profile_id"] for s in page["scopes"]}
    assert not [c for c in page["changes"] if c["scope"] == owner.self_profile_id]

    restored = await delete_and_restore_from_pending(client, owner)
    assert restored is not None
    assert len(await incoming(client, viewer)) == 1
    again = await sync_all(client, viewer, {viewer.self_profile_id: 0})  # re-pull from 0
    assert owner.self_profile_id in again.scopes
    assert medication["id"] in again.ids("medication")
    assert again.scopes[owner.self_profile_id]["role"] == "viewer"


async def delete_and_restore_from_pending(client: AsyncClient, owner: Any) -> Any:
    from tests.grace_helpers import pending_login, restore

    ticket, code = await pending_login(client, owner)
    resp = await restore(client, ticket, code)
    assert resp.status_code == 200
    return resp.json()


async def test_a_stale_cursor_of_a_relative_stays_valid_across_the_grace_period(
    client: AsyncClient,
) -> None:
    """No ``granted_seq`` bump on restore: a client that kept its cursor continues from it.

    Nobody can write to the profile during the grace period, so there is no narrowing a
    stale client could have missed; bumping ``granted_seq`` would instead suppress a
    narrowing delete the client legitimately needs.
    """
    owner, viewer = await register(client), await register(client)
    medication = await create_medication(client, owner)
    await link_accounts(client, owner, viewer, "viewer")
    synced = await sync_all(client, viewer, {viewer.self_profile_id: 0})
    cursor = synced.cursors[owner.self_profile_id]

    owner = await delete_and_restore(client, owner)
    page = await scoped_pull(client, viewer, {owner.self_profile_id: cursor})

    assert owner.self_profile_id in {s["profile_id"] for s in page["scopes"]}
    assert page["revoked"] == []
    assert page["changes"] == []  # nothing happened: the cursor is still the head
    hidden = await client.patch(
        f"/v1/medications/{medication['id']}", json={"privacy": "hidden"}, headers=owner.headers
    )
    assert hidden.status_code == 200
    page = await scoped_pull(client, viewer, {owner.self_profile_id: cursor})
    deleted = [c for c in page["changes"] if c["op"] == "delete"]
    assert [c["id"] for c in deleted] == [medication["id"]]  # the narrowing still reaches it


async def test_the_owner_sees_an_inactive_grant_and_may_revoke_it(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    grant = await link_accounts(client, owner, relative, "viewer")
    assert [g["active"] for g in await outgoing(client, owner)] == [True]

    assert (await request_deletion(client, relative)).status_code == 204

    listed = await outgoing(client, owner)
    assert [(g["id"], g["active"]) for g in listed] == [(grant["id"], False)]
    assert owner.self_profile_id not in await visible(engine, relative)
    assert (
        await client.delete(f"/v1/grants/{grant['id']}", headers=owner.headers)
    ).status_code == 204
    assert await outgoing(client, owner) == []


async def test_a_restore_reactivates_the_grants_the_account_holds(client: AsyncClient) -> None:
    owner, relative = await register(client), await register(client)
    await link_accounts(client, owner, relative, "viewer")
    relative = await delete_and_restore(client, relative)
    assert [g["active"] for g in await outgoing(client, owner)] == [True]
    assert len(await incoming(client, relative)) == 1


async def test_the_pending_account_holds_no_role_anywhere(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, guardian = await register(client), await register(client)
    ward_owner = await register(client)
    await link_accounts(client, owner, guardian, "viewer")
    await request_deletion(client, guardian)
    assert await role_of(engine, guardian, owner.self_profile_id) is None
    assert owner.self_profile_id not in await visible(engine, guardian)
    assert await visible(engine, ward_owner) == {ward_owner.self_profile_id}


async def test_pending_owner_and_grantee_both_end_the_grant(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    await link_accounts(client, owner, relative, "editor")
    await request_deletion(client, owner)
    async with access_session(engine) as session:
        stmt = access.accessible_profiles(uuid.UUID(relative.id), ["editor"])
        assert list(await session.scalars(stmt)) == []


def access_session(engine: AsyncEngine) -> Any:
    from tests.test_access import session_for

    return session_for(engine)
