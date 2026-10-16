"""Journal locks (ADR 0006 §1): sorted owner locks, enforced by ``record_change``."""

from __future__ import annotations

import asyncio
import uuid
from datetime import UTC, datetime
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession

from app.errors import AppError
from app.limits import MAX_LOCK_ATTEMPTS
from app.services import entities as svc
from app.services.changes import JournalLockError, held_owner_locks, lock_journal, record_change
from app.services.scopes import lock_stable
from tests.helpers import User, create_managed_profile, link_accounts, register
from tests.sync_helpers import make_medication, scoped_pull


async def advisory_locks_held(session: AsyncSession) -> int:
    count = await session.scalar(
        text(
            "SELECT count(*) FROM pg_locks "
            "WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND granted"
        )
    )
    return int(count or 0)


async def test_record_change_without_the_owner_lock_raises(
    client: object, engine: AsyncEngine
) -> None:
    user = await register(client)  # type: ignore[arg-type]
    profile_id = uuid.UUID(user.self_profile_id)
    async with AsyncSession(engine) as session:
        with pytest.raises(JournalLockError):
            await record_change(session, profile_id, "profile", profile_id, "upsert")
        await lock_journal(session, [uuid.UUID(user.id)])
        await record_change(session, profile_id, "profile", profile_id, "upsert")
        await session.rollback()


async def test_the_lock_of_another_owner_does_not_cover_the_scope(
    client: object, engine: AsyncEngine
) -> None:
    owner = await register(client)  # type: ignore[arg-type]
    other = await register(client)  # type: ignore[arg-type]
    profile_id = uuid.UUID(owner.self_profile_id)
    async with AsyncSession(engine) as session:
        await lock_journal(session, [uuid.UUID(other.id)])
        with pytest.raises(JournalLockError):
            await record_change(session, profile_id, "profile", profile_id, "upsert")
        await session.rollback()


async def test_locks_are_forgotten_when_the_transaction_ends(
    client: object, engine: AsyncEngine
) -> None:
    user = await register(client)  # type: ignore[arg-type]
    profile_id = uuid.UUID(user.self_profile_id)
    owner = uuid.UUID(user.id)
    async with AsyncSession(engine) as session:
        await lock_journal(session, [owner])
        assert held_owner_locks(session) == {owner}
        await session.commit()
        assert held_owner_locks(session) == set()
        with pytest.raises(JournalLockError):
            await record_change(session, profile_id, "profile", profile_id, "upsert")
        await lock_journal(session, [owner])
        await session.rollback()
        assert held_owner_locks(session) == set()


async def test_lock_journal_is_reentrant_and_takes_one_lock_per_owner(engine: AsyncEngine) -> None:
    owners = [uuid.uuid4(), uuid.uuid4()]
    async with AsyncSession(engine) as session:
        await lock_journal(session, owners)
        await lock_journal(session, [owners[1], owners[0], owners[0]])
        assert await advisory_locks_held(session) == 2
        assert held_owner_locks(session) == set(owners)
        await session.rollback()


# --- who is locked ----------------------------------------------------------------------------


async def wait_for_blocked_lock(engine: AsyncEngine, waiting: int = 1) -> None:
    """Return once ``waiting`` backends are queued on an advisory lock (no fixed sleeps)."""
    async with engine.connect() as conn:
        for _ in range(500):
            count = (
                await conn.execute(
                    text(
                        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted"
                    )
                )
            ).scalar_one()
            if count >= waiting:
                return
            await asyncio.sleep(0.01)
    pytest.fail("nobody queued on the journal lock")


def med_mutation(profile_id: str, name: str = "Locked") -> dict[str, Any]:
    return {
        "entity": "medication",
        "op": "upsert",
        "id": str(uuid.uuid4()),
        "data": {"profile_id": profile_id, "name": name},
        "client_updated_at": datetime.now(UTC).isoformat(),
    }


async def test_foreign_ids_in_a_batch_take_no_lock_and_wait_for_nobody(
    client: AsyncClient, engine: AsyncEngine, app_and_engine: tuple[Any, AsyncEngine]
) -> None:
    app = app_and_engine[0]
    owner, stranger = await register(client), await register(client)
    mid = await make_medication(client, owner, owner.self_profile_id)
    async with app.state.sessionmaker() as holder:
        await lock_journal(holder, [uuid.UUID(owner.id)])  # the owner is mid-write
        batch = [
            med_mutation(owner.self_profile_id),  # a profile the stranger cannot access
            {**med_mutation(stranger.self_profile_id), "id": mid},  # a foreign medication id
        ]
        resp = await asyncio.wait_for(
            client.post("/v1/sync/push", json={"mutations": batch}, headers=stranger.device("s")),
            timeout=5,
        )
        await holder.rollback()
    assert resp.status_code == 200
    assert [(r["status"], r["code"]) for r in resp.json()["results"]] == [
        ("rejected", "parent_not_found"),
        ("rejected", "not_found"),
    ]


async def test_an_editor_with_access_queues_behind_the_owner_lock(
    client: AsyncClient, engine: AsyncEngine, app_and_engine: tuple[Any, AsyncEngine]
) -> None:
    app = app_and_engine[0]
    owner, editor = await register(client), await register(client)
    await link_accounts(client, owner, editor, "editor")
    async with app.state.sessionmaker() as holder:
        await lock_journal(holder, [uuid.UUID(owner.id)])
        task = asyncio.create_task(
            client.post(
                "/v1/sync/push",
                json={"mutations": [med_mutation(owner.self_profile_id)]},
                headers=editor.device("e"),
            )
        )
        await wait_for_blocked_lock(engine)
        assert not task.done()
        await holder.commit()
    resp = await asyncio.wait_for(task, timeout=5)
    assert resp.json()["results"][0]["status"] == "applied"


# --- owner changes between resolving and locking ----------------------------------------------


async def test_a_transfer_between_resolve_and_lock_is_retried_with_the_new_owner(
    client: AsyncClient, engine: AsyncEngine, app_and_engine: tuple[Any, AsyncEngine]
) -> None:
    app = app_and_engine[0]
    owner, guardian = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, guardian, "guardian", ward)
    async with app.state.sessionmaker() as transfer:
        await lock_journal(transfer, [uuid.UUID(owner.id)])  # the D1 transfer holds the old owner
        patch = asyncio.create_task(
            client.patch(
                f"/v1/profiles/{ward}", json={"display_name": "Renamed"}, headers=guardian.headers
            )
        )
        await wait_for_blocked_lock(engine)  # the guardian resolved the old owner and waits
        await transfer.execute(
            text("DELETE FROM profile_grants WHERE profile_id = :p"), {"p": ward}
        )
        await transfer.execute(
            text("UPDATE profiles SET owner_user_id = :o WHERE id = :p"),
            {"o": guardian.id, "p": ward},
        )
        await transfer.commit()
    resp = await asyncio.wait_for(patch, timeout=5)
    assert resp.status_code == 200  # re-resolved: the guardian is the owner now
    assert resp.json()["display_name"] == "Renamed"
    async with engine.connect() as conn:
        rows = (
            await conn.execute(
                text("SELECT count(*) FROM sync_changes WHERE profile_id = :p AND entity_id = :p"),
                {"p": ward},
            )
        ).scalar_one()
    assert rows == 2  # creation and the rename, in the ward's scope


async def test_a_push_whose_access_vanished_while_it_waited_rejects_instead_of_locking(
    client: AsyncClient, engine: AsyncEngine, app_and_engine: tuple[Any, AsyncEngine]
) -> None:
    app = app_and_engine[0]
    owner, editor = await register(client), await register(client)
    grant = await link_accounts(client, owner, editor, "editor")
    async with app.state.sessionmaker() as holder:
        await lock_journal(holder, [uuid.UUID(owner.id)])
        task = asyncio.create_task(
            client.post(
                "/v1/sync/push",
                json={"mutations": [med_mutation(owner.self_profile_id)]},
                headers=editor.device("e"),
            )
        )
        await wait_for_blocked_lock(engine)
        await holder.execute(text("DELETE FROM profile_grants WHERE id = :g"), {"g": grant["id"]})
        await holder.commit()
    resp = await asyncio.wait_for(task, timeout=5)
    assert resp.status_code == 200
    assert [(r["status"], r["code"]) for r in resp.json()["results"]] == [
        ("rejected", "parent_not_found")
    ]


async def test_lock_stable_gives_up_with_retry_later_after_three_attempts(
    engine: AsyncEngine,
) -> None:
    calls = 0

    async def resolve() -> uuid.UUID:
        nonlocal calls
        calls += 1
        return uuid.uuid4()  # a different owner every time

    async with AsyncSession(engine) as session:
        with pytest.raises(AppError) as exc:
            await lock_stable(session, resolve, lambda owner: [owner])
    assert exc.value.status_code == 503
    assert exc.value.code == "retry_later"
    assert calls == 2 * MAX_LOCK_ATTEMPTS


# --- seq order is commit order across owner and editor ----------------------------------------


async def test_owner_and_editor_writes_to_one_scope_are_serialized(
    client: AsyncClient, engine: AsyncEngine, app_and_engine: tuple[Any, AsyncEngine]
) -> None:
    app = app_and_engine[0]
    owner, editor = await register(client), await register(client)
    await link_accounts(client, owner, editor, "editor")
    owner_id = uuid.UUID(owner.id)
    first_id = uuid.uuid4()
    second = med_mutation(owner.self_profile_id, "Second")
    async with app.state.sessionmaker() as slow:
        await lock_journal(slow, [owner_id])
        ctx = svc.WriteContext.server(owner_id, "slow")
        await svc.create_medication(
            slow,
            ctx,
            medication_id=first_id,
            profile_id=uuid.UUID(owner.self_profile_id),
            fields={"name": "First"},
        )
        task = asyncio.create_task(
            client.post(
                "/v1/sync/push",
                json={"mutations": [second]},
                headers=editor.device("e"),
            )
        )
        await wait_for_blocked_lock(engine)
        during = await scoped_pull(client, editor, {owner.self_profile_id: 0})
        assert str(first_id) not in str(during["changes"])  # uncommitted: not readable yet
        await slow.commit()
    assert (await asyncio.wait_for(task, timeout=5)).status_code == 200
    async with engine.connect() as conn:
        rows = (
            await conn.execute(
                text(
                    "SELECT entity_id, seq FROM sync_changes "
                    "WHERE profile_id = :p AND entity = 'medication' ORDER BY seq"
                ),
                {"p": owner.self_profile_id},
            )
        ).all()
    # Seq order is commit order: the slow writer's row was journaled first and committed first.
    assert [str(r[0]) for r in rows] == [str(first_id), second["id"]]
    assert rows[0][1] < rows[1][1]
    after = await scoped_pull(client, editor, {owner.self_profile_id: 0})
    cursor = next(s for s in after["scopes"] if s["profile_id"] == owner.self_profile_id)["cursor"]
    assert cursor >= rows[1][1]  # the editor's cursor is past both rows
    assert {c["id"] for c in after["changes"] if c["entity"] == "medication"} == {
        str(first_id),
        second["id"],
    }


async def test_a_reader_never_misses_a_row_while_owner_and_editor_write_concurrently(
    client: AsyncClient,
) -> None:
    owner, editor = await register(client), await register(client)
    await link_accounts(client, owner, editor, "editor")
    pid = owner.self_profile_id
    written: set[str] = set()
    done = asyncio.Event()

    async def owner_writes() -> None:
        for i in range(15):
            mid = str(uuid.uuid4())
            resp = await client.post(
                f"/v1/profiles/{pid}/medications",
                json={"id": mid, "name": f"Owner {i}"},
                headers=owner.headers,
            )
            assert resp.status_code == 201
            written.add(mid)

    async def editor_writes() -> None:
        for i in range(15):
            mutation = med_mutation(pid, f"Editor {i}")
            resp = await client.post(
                "/v1/sync/push", json={"mutations": [mutation]}, headers=editor.device("e")
            )
            assert resp.json()["results"][0]["status"] == "applied"
            written.add(mutation["id"])

    async def reader() -> set[str]:
        seen: set[str] = set()
        cursor = 0
        while True:
            finished = done.is_set()  # read the flag first: one more full pass after it is set
            page = await scoped_pull(client, owner, {pid: cursor}, limit=3)
            seen |= {c["id"] for c in page["changes"] if c["entity"] == "medication"}
            cursor = next(s["cursor"] for s in page["scopes"] if s["profile_id"] == pid)
            if finished and not page["has_more"]:
                return seen

    async def writers() -> None:
        await asyncio.gather(owner_writes(), editor_writes())
        done.set()

    seen, _ = await asyncio.gather(reader(), writers())
    assert seen == written


# --- several owners in one batch --------------------------------------------------------------


async def test_multi_owner_batches_and_rest_writes_do_not_deadlock(client: AsyncClient) -> None:
    a, b = await register(client), await register(client)
    ward_a = await create_managed_profile(client, a)
    ward_b = await create_managed_profile(client, b)
    await link_accounts(client, a, b, "guardian", ward_a)
    await link_accounts(client, b, a, "guardian", ward_b)

    async def batch(user: User, device: str) -> int:
        mutations = [
            med_mutation(ward_a, "A"),
            med_mutation(ward_b, "B"),
            med_mutation(user.self_profile_id),
        ]
        resp = await client.post(
            "/v1/sync/push", json={"mutations": mutations}, headers=user.device(device)
        )
        return resp.status_code

    async def rest(user: User, profile_id: str) -> int:
        resp = await client.post(
            f"/v1/profiles/{profile_id}/medications",
            json={"id": str(uuid.uuid4()), "name": "Rest"},
            headers=user.headers,
        )
        return resp.status_code

    jobs = []
    for i in range(6):
        jobs += [batch(a, f"a{i}"), batch(b, f"b{i}"), rest(a, ward_b), rest(b, ward_a)]
    codes = await asyncio.wait_for(asyncio.gather(*jobs), timeout=30)
    assert set(codes) <= {200, 201}
