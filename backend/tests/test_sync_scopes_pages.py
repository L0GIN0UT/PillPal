"""POST /v1/sync/pull: one snapshot per page, many scopes (ADR 0006 §2)."""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import User, create_managed_profile, link_accounts, register
from tests.sync_helpers import (
    make_medication,
    scoped_pull,
    sync_all,
)


async def two_linked(
    client: AsyncClient, role: str = "viewer"
) -> tuple[User, User, dict[str, Any]]:
    owner, relative = await register(client), await register(client)
    grant = await link_accounts(client, owner, relative, role)
    return owner, relative, grant


# --- one snapshot per page --------------------------------------------------------------------


async def test_a_page_is_read_from_one_snapshot(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A write that commits while a page is being built must not show up half-way through it."""
    from app.services import sync_pull

    owner, viewer, _ = await two_linked(client)
    await make_medication(client, owner, owner.self_profile_id)
    original = sync_pull.read_rows
    late: list[str] = []

    async def read_rows_after_a_concurrent_commit(*args: Any, **kwargs: Any) -> Any:
        if not late:  # the owner commits after the scopes were read, before the journal is
            late.append(await make_medication(client, owner, owner.self_profile_id))
        return await original(*args, **kwargs)

    monkeypatch.setattr(sync_pull, "read_rows", read_rows_after_a_concurrent_commit)
    page = await scoped_pull(client, viewer, {owner.self_profile_id: 0})
    monkeypatch.setattr(sync_pull, "read_rows", original)
    assert late
    assert late[0] not in {c["id"] for c in page["changes"]}
    again = await scoped_pull(
        client,
        viewer,
        {owner.self_profile_id: next(s["cursor"] for s in page["scopes"] if s["cursor"])},
    )
    assert [c["id"] for c in again["changes"]] == late


# --- many scopes, collapsing ------------------------------------------------------------------


async def test_with_more_than_fifty_scopes_changes_come_in_groups_of_requested_ones(
    client: AsyncClient,
) -> None:
    owner = await register(client)
    wards = [await create_managed_profile(client, owner, f"Ward {i}") for i in range(52)]
    everything = [owner.self_profile_id, *wards]

    first = await scoped_pull(client, owner, dict.fromkeys(everything[:50], 0), limit=500)
    assert {s["profile_id"] for s in first["scopes"]} == set(everything)  # every scope is listed
    assert {c["scope"] for c in first["changes"]} == set(everything[:50])
    unrequested = [s for s in first["scopes"] if s["profile_id"] in everything[50:]]
    assert [s["cursor"] for s in unrequested] == [None] * 3
    assert first["has_more"] is False

    second = await scoped_pull(client, owner, dict.fromkeys(everything[50:], 0), limit=500)
    assert {c["scope"] for c in second["changes"]} == set(everything[50:])
    assert second["revoked"] == []  # nothing restarts from 0 by omission


async def test_several_edits_of_one_entity_collapse_into_one_change_per_scope(
    client: AsyncClient,
) -> None:
    owner, viewer, _ = await two_linked(client)
    mid = await make_medication(client, owner, owner.self_profile_id)
    for name in ("one", "two", "three"):
        await client.patch(f"/v1/medications/{mid}", json={"name": name}, headers=owner.headers)
    synced = await sync_all(client, viewer, {owner.self_profile_id: 0})
    meds = [c for c in synced.changes if c["id"] == mid]
    assert len(meds) == 1
    assert meds[0]["data"]["name"] == "three"
    journal_seqs = meds[0]["seq"]
    assert journal_seqs == synced.cursors[owner.self_profile_id]  # the newest row of the entity


async def test_accessible_scopes_and_accessible_profiles_agree(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    from sqlalchemy.ext.asyncio import AsyncSession

    from app.services import access

    owner, viewer, guardian = await register(client), await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, viewer, "viewer")
    await link_accounts(client, owner, guardian, "guardian", ward)
    await client.delete(
        f"/v1/profiles/{await create_managed_profile(client, owner)}", headers=owner.headers
    )
    async with AsyncSession(engine) as session:
        for user in (owner, viewer, guardian):
            uid = uuid.UUID(user.id)
            ids = set(await session.scalars(access.accessible_profiles(uid)))
            scopes = {row[0] for row in await session.execute(access.accessible_scopes(uid))}
            assert scopes == ids
