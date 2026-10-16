"""Hidden activity never moves a relative's cursor; backfills never reveal ids (ADR 0006 §4)."""

from __future__ import annotations

import asyncio
import uuid
from typing import Any

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession

from app.services.changes import lock_journal, record_change
from tests.helpers import (
    accept_invite,
    create_invite,
    create_managed_profile,
    link_accounts,
    register,
    token_of,
)
from tests.sync_helpers import (
    make_event,
    make_medication,
    make_schedule,
    scoped_pull,
    set_privacy,
    sync_all,
)
from tests.test_sync_locks import wait_for_blocked_lock


async def journal_seqs(engine: AsyncEngine, profile_id: str) -> list[int]:
    async with engine.connect() as conn:
        rows = await conn.execute(
            text("SELECT seq FROM sync_changes WHERE profile_id = :p ORDER BY seq"),
            {"p": profile_id},
        )
        return [r[0] for r in rows]


def cursor_in(page: dict[str, Any], profile_id: str) -> int:
    return int(next(s for s in page["scopes"] if s["profile_id"] == profile_id)["cursor"])


# --- blocker 1: filtered rows are not read, so they do not move the cursor ---------------------


async def test_hidden_activity_does_not_move_the_cursor(client: AsyncClient) -> None:
    owner, viewer = await register(client), await register(client)
    await link_accounts(client, owner, viewer, "viewer")
    pid = owner.self_profile_id
    await make_medication(client, owner, pid)
    first = await sync_all(client, viewer, {pid: 0})
    hidden = await make_medication(client, owner, pid, "hidden")
    await make_schedule(client, owner, hidden)
    await make_event(client, owner, hidden)
    page = await scoped_pull(client, viewer, {pid: first.cursors[pid]})
    assert page["changes"] == []
    assert page["has_more"] is False
    assert cursor_in(page, pid) == first.cursors[pid]


async def test_pages_count_only_rows_the_relative_may_see(client: AsyncClient) -> None:
    owner, viewer = await register(client), await register(client)
    await link_accounts(client, owner, viewer, "viewer")
    pid = owner.self_profile_id
    shared = []
    for _ in range(3):
        shared.append(await make_medication(client, owner, pid))
        for _ in range(4):
            await make_medication(client, owner, pid, "hidden")
    synced = await sync_all(client, viewer, {pid: 0}, limit=2)
    assert synced.ids("medication") == set(shared)
    assert synced.pages <= 4  # profile row + 3 shared medications; the 12 hidden rows cost nothing


async def test_the_cursor_is_the_last_row_read_and_the_probe_row_is_not_consumed(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, viewer = await register(client), await register(client)
    await link_accounts(client, owner, viewer, "viewer")
    pid = owner.self_profile_id
    await make_medication(client, owner, pid)
    await make_medication(client, owner, pid, "hidden")
    await make_medication(client, owner, pid)
    seqs = await journal_seqs(engine, pid)  # profile, shared, hidden, shared
    page = await scoped_pull(client, viewer, {pid: 0}, limit=2)
    assert page["has_more"] is True
    assert cursor_in(page, pid) == seqs[1]  # the third row (visible) is the probe
    last = await scoped_pull(client, viewer, {pid: seqs[1]}, limit=2)
    assert last["has_more"] is False
    assert cursor_in(last, pid) == seqs[3]


async def test_a_guardian_and_the_owner_still_read_hidden_rows(client: AsyncClient) -> None:
    owner, guardian = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, guardian, "guardian", ward)
    hidden = await make_medication(client, owner, ward, "hidden")
    synced = await sync_all(client, guardian, {ward: 0})
    assert hidden in synced.ids("medication")


# --- blocker 2: backfill_until and granted_seq --------------------------------------------------


async def test_accepting_an_invite_stores_the_journal_head_as_granted_seq(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, viewer = await register(client), await register(client)
    await make_medication(client, owner, owner.self_profile_id)
    grant = await link_accounts(client, owner, viewer, "viewer")
    head = (await journal_seqs(engine, owner.self_profile_id))[-1]
    async with engine.connect() as conn:
        stored = (
            await conn.execute(
                text("SELECT granted_seq FROM profile_grants WHERE id = :g"), {"g": grant["id"]}
            )
        ).scalar_one()
    assert stored == head


async def test_a_backfill_starting_at_zero_returns_a_marker_until_it_is_reached(
    client: AsyncClient,
) -> None:
    owner, viewer = await register(client), await register(client)
    await link_accounts(client, owner, viewer, "viewer")
    pid = owner.self_profile_id
    for _ in range(4):
        await make_medication(client, owner, pid)
    first = await scoped_pull(client, viewer, {pid: 0}, limit=2)
    marker = next(s for s in first["scopes"] if s["profile_id"] == pid)["backfill_until"]
    assert marker is not None
    assert marker > cursor_in(first, pid)
    rest = await sync_all(client, viewer, {pid: cursor_in(first, pid)}, limit=2)
    assert rest.backfill_until.get(pid) is None  # cleared once the cursor reached it
    assert rest.cursors[pid] >= marker


async def test_a_scope_that_is_not_backfilling_has_no_marker(client: AsyncClient) -> None:
    owner, viewer = await register(client), await register(client)
    await link_accounts(client, owner, viewer, "viewer")
    pid = owner.self_profile_id
    await make_medication(client, owner, pid)
    done = await sync_all(client, viewer, {pid: 0})
    page = await scoped_pull(client, viewer, done.cursors)
    assert next(s for s in page["scopes"] if s["profile_id"] == pid)["backfill_until"] is None


async def test_a_multi_page_backfill_never_reveals_narrowed_medications(
    client: AsyncClient,
) -> None:
    owner, viewer = await register(client), await register(client)
    pid = owner.self_profile_id
    kept = [await make_medication(client, owner, pid) for _ in range(3)]
    narrowed = [await make_medication(client, owner, pid) for _ in range(3)]
    await link_accounts(client, owner, viewer, "viewer")
    for mid in narrowed:
        await set_privacy(client, owner, mid, "hidden")
    synced = await sync_all(client, viewer, {pid: 0}, limit=2)
    assert synced.pages > 2
    assert synced.ids("medication") == set(kept)
    assert synced.of("medication", "delete") == []
    assert all(mid not in str(synced.changes) for mid in narrowed)


async def test_a_medication_narrowed_during_a_backfill_is_not_a_delete(
    client: AsyncClient,
) -> None:
    owner, viewer = await register(client), await register(client)
    pid = owner.self_profile_id
    meds = [await make_medication(client, owner, pid) for _ in range(4)]
    await link_accounts(client, owner, viewer, "viewer")
    first = await scoped_pull(client, viewer, {pid: 0}, limit=2)
    marker = next(s for s in first["scopes"] if s["profile_id"] == pid)["backfill_until"]
    await set_privacy(client, owner, meds[3], "hidden")  # after the snapshot of page 1
    rest = await sync_all(
        client, viewer, {pid: cursor_in(first, pid)}, limit=2, backfill_until={pid: marker}
    )
    assert meds[3] not in str(rest.changes)


async def test_a_narrowing_committed_before_accept_is_never_a_delete(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, viewer = await register(client), await register(client)
    pid = owner.self_profile_id
    mid = await make_medication(client, owner, pid)
    invite = await create_invite(client, owner, None, "viewer")
    await set_privacy(client, owner, mid, "hidden")
    assert (await accept_invite(client, viewer, token_of(invite))).status_code == 201
    probe = await scoped_pull(client, viewer, {pid: 1})  # hostile non-zero cursor
    assert mid not in str(probe["changes"])


async def test_a_narrowing_committed_concurrently_with_accept_is_ordered_by_the_lock(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, viewer = await register(client), await register(client)
    pid = owner.self_profile_id
    mid = await make_medication(client, owner, pid)
    invite = await create_invite(client, owner, None, "viewer")
    async with AsyncSession(engine) as writer:
        await lock_journal(writer, [uuid.UUID(owner.id)])
        await writer.execute(
            text("UPDATE medications SET privacy = 'hidden' WHERE id = :m"), {"m": mid}
        )
        await record_change(writer, uuid.UUID(pid), "medication", uuid.UUID(mid), "privacy")
        accepting = asyncio.create_task(accept_invite(client, viewer, token_of(invite)))
        await wait_for_blocked_lock(engine)  # accept waits for the narrowing's lock
        await writer.commit()
    assert (await accepting).status_code == 201
    seqs = await journal_seqs(engine, pid)
    async with engine.connect() as conn:
        granted = (
            await conn.execute(
                text("SELECT granted_seq FROM profile_grants WHERE grantee_user_id = :u"),
                {"u": viewer.id},
            )
        ).scalar_one()
    assert granted == seqs[-1]  # the privacy row is inside the grant's snapshot
    for cursor in (0, 1, granted - 1):
        page = await scoped_pull(client, viewer, {pid: cursor})
        assert mid not in str(page["changes"])


async def test_a_medication_created_and_hidden_after_the_cursor_is_never_a_delete(
    client: AsyncClient,
) -> None:
    owner, viewer = await register(client), await register(client)
    await link_accounts(client, owner, viewer, "viewer")
    pid = owner.self_profile_id
    first = await sync_all(client, viewer, {pid: 0})
    mid = await make_medication(client, owner, pid)
    await set_privacy(client, owner, mid, "hidden")
    page = await scoped_pull(client, viewer, {pid: first.cursors[pid]})
    assert mid not in str(page["changes"])


async def test_narrowing_split_across_pages_for_a_medication_the_client_holds_is_a_delete(
    client: AsyncClient,
) -> None:
    owner, viewer = await register(client), await register(client)
    await link_accounts(client, owner, viewer, "viewer")
    pid = owner.self_profile_id
    mid = await make_medication(client, owner, pid)
    first = await sync_all(client, viewer, {pid: 0})
    assert mid in first.ids("medication")
    await set_privacy(client, owner, mid, "hidden")
    for _ in range(3):
        await make_medication(client, owner, pid)
    synced = await sync_all(client, viewer, first.cursors, limit=1)
    assert synced.ids("medication", "delete") == {mid}


# --- should-fix 3: no tombstones from before the grant -----------------------------------------


async def test_a_backfill_carries_no_tombstones_of_entities_deleted_before_the_grant(
    client: AsyncClient,
) -> None:
    owner, viewer = await register(client), await register(client)
    pid = owner.self_profile_id
    gone = await make_medication(client, owner, pid)
    gone_schedule = await make_schedule(client, owner, gone)
    anonymous = await make_medication(client, owner, pid, "anonymous")
    for path in (f"/v1/medications/{gone}", f"/v1/medications/{anonymous}"):
        assert (await client.delete(path, headers=owner.headers)).status_code == 204
    await link_accounts(client, owner, viewer, "viewer")
    synced = await sync_all(client, viewer, {pid: 0})
    assert synced.of("medication", "delete") == []
    assert gone_schedule not in synced.ids("schedule")
    assert anonymous not in synced.ids("medication")


async def test_a_delete_after_the_backfill_reaches_the_client(client: AsyncClient) -> None:
    owner, viewer = await register(client), await register(client)
    await link_accounts(client, owner, viewer, "viewer")
    pid = owner.self_profile_id
    mid = await make_medication(client, owner, pid)
    first = await sync_all(client, viewer, {pid: 0})
    assert (await client.delete(f"/v1/medications/{mid}", headers=owner.headers)).status_code == 204
    page = await scoped_pull(client, viewer, first.cursors)
    assert [(c["id"], c["op"]) for c in page["changes"]] == [(mid, "delete")]
