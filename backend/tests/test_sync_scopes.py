"""POST /v1/sync/pull: scopes, per-scope cursors, revocation (ADR 0006 §2)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import User, create_managed_profile, link_accounts, register
from tests.sync_helpers import (
    make_event,
    make_medication,
    make_schedule,
    push_as,
    revoke,
    scoped_pull,
    set_privacy,
    sync_all,
)
from tests.test_sync import mut


async def two_linked(
    client: AsyncClient, role: str = "viewer"
) -> tuple[User, User, dict[str, Any]]:
    owner, relative = await register(client), await register(client)
    grant = await link_accounts(client, owner, relative, role)
    return owner, relative, grant


# --- request validation, authentication ------------------------------------------------------


async def test_pull_needs_a_token_and_a_device_id(client: AsyncClient) -> None:
    user = await register(client)
    body = {"cursors": {user.self_profile_id: 0}}
    assert (await client.post("/v1/sync/pull", json=body)).status_code == 401
    no_device = await client.post("/v1/sync/pull", json=body, headers=user.headers)
    assert no_device.status_code == 422
    bad_device = await client.post("/v1/sync/pull", json=body, headers=user.device("bad id!"))
    assert bad_device.status_code == 422


@pytest.mark.parametrize(
    "body",
    [
        {"cursors": {}},
        {"cursors": {str(uuid.uuid4()): -1}},
        {"cursors": {str(uuid.uuid4()): 2**63}},
        {"cursors": {"not-a-uuid": 0}},
        {"cursors": {str(uuid.uuid4()): "0"}},
        {"cursors": {str(uuid.uuid4()): 0}, "limit": 0},
        {"cursors": {str(uuid.uuid4()): 0}, "limit": 501},
        {"cursors": {str(uuid.uuid4()): 0}, "surprise": 1},
        {},
    ],
)
async def test_pull_rejects_malformed_requests(client: AsyncClient, body: dict[str, Any]) -> None:
    user = await register(client)
    resp = await client.post("/v1/sync/pull", json=body, headers=user.device("d"))
    assert resp.status_code == 422


async def test_pull_accepts_50_cursors_and_rejects_51(client: AsyncClient) -> None:
    user = await register(client)
    fifty = {str(uuid.uuid4()): 0 for _ in range(50)}
    page = await scoped_pull(client, user, fifty)
    assert sorted(page["revoked"]) == sorted(fifty)
    await scoped_pull(client, user, {**fifty, str(uuid.uuid4()): 0}, expect=422)


# --- the shape of a response -------------------------------------------------------------------


async def test_owner_pull_lists_every_scope_with_role_kind_and_cursor(client: AsyncClient) -> None:
    owner = await register(client)
    ward = await create_managed_profile(client, owner)
    page = await scoped_pull(client, owner, {owner.self_profile_id: 0})
    scopes = {s["profile_id"]: s for s in page["scopes"]}
    assert set(scopes) == {owner.self_profile_id, ward}
    assert (scopes[owner.self_profile_id]["role"], scopes[owner.self_profile_id]["kind"]) == (
        "owner",
        "self",
    )
    assert (scopes[ward]["role"], scopes[ward]["kind"]) == ("owner", "managed")
    assert scopes[owner.self_profile_id]["cursor"] > 0
    assert scopes[ward]["cursor"] is None  # listed, but not requested
    assert page["changes"]
    assert all(c["scope"] == owner.self_profile_id for c in page["changes"])
    assert scopes[ward]["archived"] is False
    assert scopes[ward]["archive_purge_after"] is None


async def test_changes_come_only_for_requested_scopes(client: AsyncClient) -> None:
    owner = await register(client)
    ward = await create_managed_profile(client, owner)
    await make_medication(client, owner, ward)
    only_self = await scoped_pull(client, owner, {owner.self_profile_id: 0})
    assert {c["scope"] for c in only_self["changes"]} == {owner.self_profile_id}
    both = await sync_all(client, owner)
    assert {c["scope"] for c in both.changes} == {owner.self_profile_id, ward}


async def test_each_scope_has_its_own_cursor(client: AsyncClient) -> None:
    owner = await register(client)
    ward = await create_managed_profile(client, owner)
    first = await sync_all(client, owner)
    await make_medication(client, owner, ward)
    again = await sync_all(client, owner, first.cursors)
    assert [c["entity"] for c in again.changes] == ["medication"]
    assert again.cursors[ward] > first.cursors[ward]
    assert again.cursors[owner.self_profile_id] == first.cursors[owner.self_profile_id]


# --- grants: backfill, revocation ------------------------------------------------------------


async def test_a_new_grant_backfills_from_zero_across_pages(client: AsyncClient) -> None:
    owner, viewer, _ = await two_linked(client)
    meds = [await make_medication(client, owner, owner.self_profile_id) for _ in range(5)]
    synced = await sync_all(client, viewer, {owner.self_profile_id: 0}, limit=2)
    assert synced.ids("medication") == set(meds)
    assert synced.pages >= 3
    assert synced.scopes[owner.self_profile_id]["role"] == "viewer"
    # Own scope is listed too and is picked up at cursor 0 by the loop above.
    assert viewer.self_profile_id in synced.scopes


async def test_a_revoked_scope_leaves_scopes_and_lands_in_revoked(client: AsyncClient) -> None:
    owner, viewer, grant = await two_linked(client)
    first = await sync_all(client, viewer, {owner.self_profile_id: 0})
    await revoke(client, owner, grant)
    page = await scoped_pull(client, viewer, first.cursors)
    assert page["revoked"] == [owner.self_profile_id]
    assert owner.self_profile_id not in {s["profile_id"] for s in page["scopes"]}
    assert all(c["scope"] != owner.self_profile_id for c in page["changes"])


async def test_a_revoked_scope_is_not_listed_even_when_not_requested(client: AsyncClient) -> None:
    owner, viewer, grant = await two_linked(client)
    await revoke(client, owner, grant)
    page = await scoped_pull(client, viewer, {viewer.self_profile_id: 0})
    assert owner.self_profile_id not in {s["profile_id"] for s in page["scopes"]}
    assert page["revoked"] == []


async def test_foreign_and_never_existed_scopes_look_the_same(client: AsyncClient) -> None:
    owner, stranger = await register(client), await register(client)
    await make_medication(client, owner, owner.self_profile_id)
    never = str(uuid.uuid4())
    page = await scoped_pull(client, stranger, {owner.self_profile_id: 0, never: 0})
    assert sorted(page["revoked"]) == sorted([owner.self_profile_id, never])
    assert all(c["scope"] == stranger.self_profile_id or False for c in page["changes"]) or (
        page["changes"] == []
    )
    assert {s["profile_id"] for s in page["scopes"]} == {stranger.self_profile_id}


async def test_a_requested_scope_with_a_foreign_cursor_value_reveals_nothing(
    client: AsyncClient,
) -> None:
    owner, stranger = await register(client), await register(client)
    await make_medication(client, owner, owner.self_profile_id)
    page = await scoped_pull(client, stranger, {owner.self_profile_id: 0}, limit=1)
    assert page["changes"] == []
    assert page["has_more"] is False


# --- tombstoned and deleted scopes -------------------------------------------------------------


async def test_an_owned_tombstoned_scope_is_listed_only_while_the_cursor_is_below_it(
    client: AsyncClient,
) -> None:
    owner = await register(client)
    ward = await create_managed_profile(client, owner)
    before = await sync_all(client, owner)
    assert ward in before.cursors
    resp = await client.delete(f"/v1/profiles/{ward}", headers=owner.headers)
    assert resp.status_code == 204

    not_requested = await scoped_pull(client, owner, {owner.self_profile_id: 0})
    assert ward not in {s["profile_id"] for s in not_requested["scopes"]}

    page = await scoped_pull(client, owner, before.cursors)
    assert ward in {s["profile_id"] for s in page["scopes"]}
    assert [(c["entity"], c["op"]) for c in page["changes"] if c["scope"] == ward] == [
        ("profile", "delete")
    ]
    cursors = {s["profile_id"]: s["cursor"] for s in page["scopes"] if s["cursor"] is not None}
    after = await scoped_pull(client, owner, cursors)
    assert after["revoked"] == [ward]
    assert ward not in {s["profile_id"] for s in after["scopes"]}


async def test_deleting_a_managed_profile_revokes_the_guardians_scope(client: AsyncClient) -> None:
    owner, guardian = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, guardian, "guardian", ward)
    synced = await sync_all(client, guardian, {ward: 0})
    assert synced.scopes[ward]["role"] == "guardian"
    assert (await client.delete(f"/v1/profiles/{ward}", headers=owner.headers)).status_code == 204
    page = await scoped_pull(client, guardian, synced.cursors)
    assert ward in page["revoked"]
    assert ward not in {s["profile_id"] for s in page["scopes"]}
    assert all(c["scope"] != ward for c in page["changes"])


# --- what the envelope and the scope disclose -------------------------------------------------


async def test_projected_roles_never_see_the_writing_device(client: AsyncClient) -> None:
    owner, viewer, _ = await two_linked(client)
    mid = str(uuid.uuid4())
    await push_as(
        client,
        owner,
        [mut("medication", "upsert", mid, {"profile_id": owner.self_profile_id, "name": "Pill"})],
        device="owner-phone",
    )
    seen_by_owner = await sync_all(client, owner)
    seen_by_viewer = await sync_all(client, viewer, {owner.self_profile_id: 0})
    assert seen_by_owner.by_id(mid)["updated_by_device"] == "owner-phone"
    assert seen_by_viewer.by_id(mid)["updated_by_device"] is None
    shared_scope = [c for c in seen_by_viewer.changes if c["scope"] == owner.self_profile_id]
    assert shared_scope
    assert all(c["updated_by_device"] is None for c in shared_scope)


async def test_owner_last_seen_is_floored_to_the_hour_and_only_on_foreign_self_scopes(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, viewer, _ = await two_linked(client)
    ward = await create_managed_profile(client, owner)
    guardian_link = await register(client)
    await link_accounts(client, owner, guardian_link, "guardian", ward)
    await push_as(client, owner, [], device="owner-phone")
    async with engine.begin() as conn:
        await conn.execute(
            text("UPDATE devices SET last_seen_at = :t WHERE user_id = :u"),
            {"t": datetime(2026, 10, 16, 8, 47, 12, tzinfo=UTC), "u": owner.id},
        )
    page = await scoped_pull(client, viewer, {owner.self_profile_id: 0})
    scopes = {s["profile_id"]: s for s in page["scopes"]}
    assert scopes[owner.self_profile_id]["owner_last_seen_at"] == "2026-10-16T08:00:00Z"
    assert scopes[viewer.self_profile_id]["owner_last_seen_at"] is None  # own scope
    guarded = await scoped_pull(client, guardian_link, {ward: 0})
    managed = next(s for s in guarded["scopes"] if s["profile_id"] == ward)
    assert managed["owner_last_seen_at"] is None  # managed scopes never expose it
    own_view = await scoped_pull(client, owner, {owner.self_profile_id: 0})
    assert all(s["owner_last_seen_at"] is None for s in own_view["scopes"])


async def test_a_pull_touches_the_device_at_most_once_per_interval(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)

    async def last_seen() -> datetime:
        async with engine.connect() as conn:
            row = await conn.execute(
                text("SELECT last_seen_at FROM devices WHERE user_id = :u AND device_id = 'phone'"),
                {"u": user.id},
            )
            value: datetime = row.scalar_one()
            return value

    async def set_last_seen(age: timedelta) -> datetime:
        stamp = datetime.now(UTC) - age
        async with engine.begin() as conn:
            await conn.execute(
                text("UPDATE devices SET last_seen_at = :t WHERE user_id = :u"),
                {"t": stamp, "u": user.id},
            )
        return stamp

    await scoped_pull(client, user, {user.self_profile_id: 0}, device="phone")  # creates it
    recent = await set_last_seen(timedelta(minutes=1))
    await scoped_pull(client, user, {user.self_profile_id: 0}, device="phone")
    assert await last_seen() == recent  # inside the interval: no write
    stale = await set_last_seen(timedelta(minutes=10))
    await scoped_pull(client, user, {user.self_profile_id: 0}, device="phone")
    assert await last_seen() > stale


# --- parents before children --------------------------------------------------------------------


async def test_parents_come_before_children_within_a_page(client: AsyncClient) -> None:
    owner, viewer, _ = await two_linked(client)
    mid = await make_medication(client, owner, owner.self_profile_id)
    sid = await make_schedule(client, owner, mid)
    eid = await make_event(client, owner, mid)
    first = await sync_all(client, viewer, {owner.self_profile_id: 0})
    # Edits in child-then-parent order: the schedule's row now precedes the medication's.
    await client.patch(
        f"/v1/schedules/{sid}",
        json={"rule": first.by_id(sid)["data"]["rule"]},
        headers=owner.headers,
    )
    await client.patch(f"/v1/medications/{mid}", json={"name": "Renamed"}, headers=owner.headers)
    page = await scoped_pull(
        client, viewer, {owner.self_profile_id: first.cursors[owner.self_profile_id]}
    )
    assert [c["entity"] for c in page["changes"]] == ["medication", "schedule"]
    full = await sync_all(client, viewer, {owner.self_profile_id: 0})
    order = [c["entity"] for c in full.changes if c["scope"] == owner.self_profile_id]
    assert order == sorted(
        order, key={"profile": 0, "medication": 1, "schedule": 2, "dose_event": 3}.get
    )
    assert eid in full.ids("dose_event")


# --- compatibility: the Phase 2 single-cursor pull --------------------------------------------


async def test_the_legacy_pull_still_serves_owner_scopes_with_the_new_fields(
    client: AsyncClient,
) -> None:
    owner, editor, _ = await two_linked(client, "editor")
    ward = await create_managed_profile(client, owner)
    mid = str(uuid.uuid4())
    await push_as(
        client,
        editor,
        [
            mut(
                "medication",
                "upsert",
                mid,
                {"profile_id": owner.self_profile_id, "name": "By editor"},
            )
        ],
        device="editor-phone",
    )
    resp = await client.get("/v1/sync/pull", params={"cursor": 0}, headers=owner.headers)
    assert resp.status_code == 200
    body = resp.json()
    by_id = {c["id"]: c for c in body["changes"]}
    assert {owner.self_profile_id, ward, mid} <= set(by_id)
    assert by_id[mid]["scope"] == owner.self_profile_id
    assert by_id[mid]["updated_by_device"] == "editor-phone"
    # A relative's legacy pull shows only what they own, never the shared scope.
    theirs = (
        await client.get("/v1/sync/pull", params={"cursor": 0}, headers=editor.headers)
    ).json()
    assert {c["scope"] for c in theirs["changes"]} == {editor.self_profile_id}


async def test_privacy_rows_are_plain_upserts_on_the_legacy_pull(client: AsyncClient) -> None:
    owner = await register(client)
    mid = await make_medication(client, owner, owner.self_profile_id)
    await set_privacy(client, owner, mid, "anonymous")
    body = (await client.get("/v1/sync/pull", params={"cursor": 0}, headers=owner.headers)).json()
    med = next(c for c in body["changes"] if c["id"] == mid)
    assert med["op"] == "upsert"
    assert med["data"]["privacy"] == "anonymous"
