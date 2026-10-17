"""Sync journal: per-user write serialization, id collisions, cursor bounds."""

from __future__ import annotations

import asyncio
import uuid
from datetime import UTC, datetime
from typing import Any

import pytest
from fastapi.routing import APIRoute
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession

from app.api import resources
from app.config import Settings
from app.db.models import Profile
from app.deps import (
    lock_medication_scope,
    lock_own_scope,
    lock_profile_scope,
    lock_profile_scope_for_purge,
    lock_schedule_scope,
)
from app.errors import AppError
from app.services import entities as svc
from app.services.changes import lock_journal
from tests.helpers import register
from tests.test_sync import med_data, mut, pull, push


def by_id(page: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {c["id"]: c for c in page["changes"]}


# --- 1. journal writes are serialized per user -----------------------------------


async def test_pull_never_skips_a_change_committed_out_of_seq_order(
    client: AsyncClient, app_and_engine: tuple[Any, AsyncEngine], settings: Settings
) -> None:
    app = app_and_engine[0]
    user = await register(client)
    uid = uuid.UUID(user.id)
    t1_profile = uuid.uuid4()
    mid, pid2 = str(uuid.uuid4()), str(uuid.uuid4())

    async with app.state.sessionmaker() as t1:
        # T1 journals a change (gets the lower seq) and keeps its transaction open.
        await lock_journal(t1, [uid])
        ctx = svc.WriteContext.server(uid, "t1")
        await svc.create_profile(
            t1, ctx, settings=settings, profile_id=t1_profile, display_name="Slow", timezone="UTC"
        )

        # T2 (a sync push) and T3 (a REST write) of the same user must wait for T1.
        t2 = asyncio.create_task(
            client.post(
                "/v1/sync/push",
                json={
                    "mutations": [mut("medication", "upsert", mid, med_data(user.self_profile_id))]
                },
                headers=user.device("t2"),
            )
        )
        t3 = asyncio.create_task(
            client.post(
                "/v1/profiles",
                json={"id": pid2, "display_name": "Rest", "timezone": "UTC"},
                headers=user.headers,
            )
        )
        await asyncio.sleep(0.5)
        assert not t2.done(), "push did not wait for the journal lock"
        assert not t3.done(), "REST write did not wait for the journal lock"

        # A pull now sees neither T1 (uncommitted) nor anything after it.
        cursor = (await pull(client, user))["next_cursor"]
        await t1.commit()

    assert (await t2).status_code == 200
    assert (await t3).status_code == 201
    later = await pull(client, user, cursor=cursor)
    assert {str(t1_profile), mid, pid2} <= set(by_id(later))


# --- 10. only primary-key collisions are "already_exists" --------------------------------


async def test_only_primary_key_collisions_map_to_already_exists(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    uid = uuid.UUID(user.id)

    def profile(pid: uuid.UUID, display_name: str) -> Profile:
        return Profile(
            id=pid,
            owner_user_id=uid,
            kind="managed",
            display_name=display_name,
            timezone="UTC",
            version=1,
            client_updated_at=datetime.now(UTC),
            updated_by_device="",
        )

    async with AsyncSession(engine) as session:
        with pytest.raises(AppError) as exc:
            await svc.insert_new(session, profile(uuid.UUID(user.self_profile_id), "Dup"))
        assert exc.value.code == "already_exists"
        # A CHECK violation is a bug, not an id collision: it must surface as-is.
        with pytest.raises(IntegrityError):
            await svc.insert_new(session, profile(uuid.uuid4(), ""))
        await session.rollback()


# --- 13. huge cursors are a validation error, not a 500 ----------------------------------


async def test_the_phase_2_get_pull_is_gone(client: AsyncClient) -> None:
    user = await register(client)
    resp = await client.get("/v1/sync/pull", params={"cursor": 0}, headers=user.headers)
    assert resp.status_code == 405


async def test_pull_cursor_is_bounded_to_bigint(client: AsyncClient) -> None:
    user = await register(client)
    pid = user.self_profile_id
    headers = user.device("d")
    resp = await client.post("/v1/sync/pull", json={"cursors": {pid: 2**63}}, headers=headers)
    assert resp.status_code == 422
    resp = await client.post("/v1/sync/pull", json={"cursors": {pid: 2**63 - 1}}, headers=headers)
    assert resp.status_code == 200
    assert resp.json()["changes"] == []


async def test_journal_lock_helper_is_reentrant(engine: AsyncEngine) -> None:
    async with AsyncSession(engine) as session:
        uid = uuid.uuid4()
        await lock_journal(session, [uid])
        await lock_journal(session, [uid])
        held = await session.scalar(
            text(
                "SELECT count(*) FROM pg_locks "
                "WHERE locktype = 'advisory' AND pid = pg_backend_pid()"
            )
        )
        assert held == 1
        await session.rollback()


def test_every_rest_write_route_takes_the_journal_lock() -> None:
    writes = [
        r
        for r in resources.router.routes
        if isinstance(r, APIRoute) and r.methods & {"POST", "PATCH", "PUT", "DELETE"}
    ]
    assert len(writes) == 10
    locks = {
        lock_own_scope,
        lock_profile_scope,
        lock_profile_scope_for_purge,
        lock_medication_scope,
        lock_schedule_scope,
    }
    for route in writes:
        calls = {d.call for d in route.dependant.dependencies}
        if route.path == "/v1/dose-events":
            continue  # the medication id is in the body: the handler locks inline (see below)
        assert calls & locks, route.path


async def test_pull_paginates(client: AsyncClient) -> None:
    user = await register(client)
    pid = user.self_profile_id
    mids = [str(uuid.uuid4()) for _ in range(5)]
    await push(client, user, "d", [mut("medication", "upsert", m, med_data(pid)) for m in mids])
    seen: list[str] = []
    cursor, pages = 0, 0
    while True:
        page = await pull(client, user, cursor=cursor, limit=2)
        seen += [c["id"] for c in page["changes"] if c["entity"] == "medication"]
        cursor, pages = page["next_cursor"], pages + 1
        if not page["has_more"]:
            break
    assert seen == mids
    assert pages == 3  # 6 changes (self profile + 5) in pages of 2
    for bad in ({"limit": 501}, {"limit": 0}):
        body = {"cursors": {pid: 0}, **bad}
        resp = await client.post("/v1/sync/pull", json=body, headers=user.device("d"))
        assert resp.status_code == 422


async def test_push_batch_size_is_bounded(client: AsyncClient) -> None:
    user = await register(client)
    mutations = [mut("medication", "delete", str(uuid.uuid4()), None) for _ in range(501)]
    resp = await client.post(
        "/v1/sync/push", json={"mutations": mutations}, headers=user.device("d")
    )
    assert resp.status_code == 422
