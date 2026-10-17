"""A late mark resolves the alert and tells the recipients, recomputed by rule; a `missed` is never
re-sent (ADR 0007 §3). Also the races of a late mark and of an account deletion with a tick."""

from __future__ import annotations

import asyncio
import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.config import Settings
from app.services.changes import lock_journal
from app.services.missed_doses import detect_missed_doses
from tests.detector_helpers import (
    World,
    alert_rows,
    at,
    check_window,
    make_world,
    missed_pushes,
    recipients_of_pushes,
    register_token,
    set_watermark,
    sql,
)
from tests.helpers import User, link_accounts, register
from tests.sync_helpers import push_as
from tests.test_sync import mut

Maker = async_sessionmaker[AsyncSession]


def _now_iso(minutes: int = 0) -> str:
    """The write paths refuse instants in the future, and the real clock is what they see."""
    return (datetime.now(UTC) + timedelta(minutes=minutes)).isoformat()


async def _alerted(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings, **kw: Any
) -> World:
    world = await make_world(client, engine, **kw)
    assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 1
    return world


async def _late_mark(
    client: AsyncClient, world: World, type_: str = "taken", user: User | None = None
) -> Any:
    return await client.post(
        "/v1/dose-events",
        json={
            "id": str(uuid.uuid4()),
            "medication_id": world.medication_id,
            "type": type_,
            "at": _now_iso(),
            "occurrence_key": world.key(),
        },
        headers={**(user or world.owner).headers, "X-Device-ID": "phone-1"},
    )


async def test_a_late_taken_resolves_the_alert_and_tells_the_recipients(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await _alerted(client, engine, maker, settings, relatives=("viewer", "editor"))
    resp = await _late_mark(client, world)
    assert resp.status_code == 201, resp.text
    [alert] = await alert_rows(engine)
    assert alert.resolved_at is not None
    resolved = await missed_pushes(engine, "resolved")
    assert recipients_of_pushes(resolved) == sorted(
        [world.relatives["viewer"].id, world.relatives["editor"].id]
    )
    assert resolved[0].payload == {
        "v": 1,
        "t": "resolved",
        "a": str(alert.id),
        "p": world.profile_id,
        "m": world.medication_id,
    }
    assert len(await missed_pushes(engine)) == 2  # the `missed` pushes are not re-sent


async def test_a_late_skipped_resolves_too(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await _alerted(client, engine, maker, settings)
    assert (await _late_mark(client, world, "skipped")).status_code == 201
    assert (await alert_rows(engine))[0].resolved_at is not None
    assert len(await missed_pushes(engine, "resolved")) == 1


async def test_a_second_late_event_resolves_nothing_more(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await _alerted(client, engine, maker, settings)
    assert (await _late_mark(client, world)).status_code == 201
    first = (await alert_rows(engine))[0].resolved_at
    assert (await _late_mark(client, world, "skipped")).status_code == 201
    assert (await alert_rows(engine))[0].resolved_at == first
    assert len(await missed_pushes(engine, "resolved")) == 1


async def test_an_idempotent_replay_does_not_resolve_twice(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await _alerted(client, engine, maker, settings)
    body = {
        "id": str(uuid.uuid4()),
        "medication_id": world.medication_id,
        "type": "taken",
        "at": _now_iso(),
        "occurrence_key": world.key(),
    }
    headers = {**world.owner.headers, "X-Device-ID": "phone-1"}
    assert (await client.post("/v1/dose-events", json=body, headers=headers)).status_code == 201
    assert (await client.post("/v1/dose-events", json=body, headers=headers)).status_code == 200
    assert len(await missed_pushes(engine, "resolved")) == 1


async def test_a_mark_with_no_alert_enqueues_nothing(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    world = await make_world(client, engine)
    assert (await _late_mark(client, world)).status_code == 201
    assert await missed_pushes(engine, "resolved") == []


async def test_a_late_taken_through_sync_push_resolves_the_alert(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await _alerted(client, engine, maker, settings)
    results = await push_as(
        client,
        world.owner,
        [
            mut(
                "dose_event",
                "upsert",
                str(uuid.uuid4()),
                {
                    "medication_id": world.medication_id,
                    "type": "taken",
                    "at": _now_iso(),
                    "occurrence_key": world.key(),
                },
            )
        ],
        device="phone-1",
    )
    assert results[0]["status"] == "applied"
    assert (await alert_rows(engine))[0].resolved_at is not None
    assert len(await missed_pushes(engine, "resolved")) == 1


async def test_a_snooze_or_an_undo_does_not_resolve(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await _alerted(client, engine, maker, settings)
    resp = await client.post(
        "/v1/dose-events",
        json={
            "id": str(uuid.uuid4()),
            "medication_id": world.medication_id,
            "type": "snoozed",
            "at": _now_iso(),
            "snooze_until": _now_iso(minutes=10),
            "occurrence_key": world.key(),
        },
        headers=world.owner.headers,
    )
    assert resp.status_code == 201, resp.text
    assert (await alert_rows(engine))[0].resolved_at is None


async def test_resolved_goes_to_the_recipients_by_the_rule_at_resolution_time(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await _alerted(client, engine, maker, settings, relatives=("viewer", "editor"))
    # The editor left after the alert; someone linked after the dose was due. Neither is told.
    await sql(
        engine,
        "DELETE FROM profile_grants WHERE grantee_user_id = :u",
        u=uuid.UUID(world.relatives["editor"].id),
    )
    newcomer = await register(client)
    await link_accounts(client, world.owner, newcomer, "viewer", world.profile_id)
    await register_token(client, newcomer, "dev-1")
    await sql(
        engine,
        "UPDATE profile_grants SET created_at = :t WHERE grantee_user_id = :u",
        t=at(8, 10),
        u=uuid.UUID(newcomer.id),
    )
    assert (await _late_mark(client, world)).status_code == 201
    resolved = await missed_pushes(engine, "resolved")
    assert recipients_of_pushes(resolved) == [world.relatives["viewer"].id]


async def test_resolved_honours_hidden_and_anonymous_like_the_alert(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    hidden = await _alerted(
        client,
        engine,
        maker,
        settings,
        managed=True,
        relatives=("guardian", "viewer"),
        privacy="hidden",
    )
    assert (await _late_mark(client, hidden)).status_code == 201
    pushes = await missed_pushes(engine, "resolved")
    assert recipients_of_pushes(pushes) == [hidden.relatives["guardian"].id]
    assert all(p.payload["m"] == hidden.medication_id for p in pushes)


async def test_resolved_without_the_medication_id_for_relatives_of_anonymous_ones(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await _alerted(
        client, engine, maker, settings, relatives=("viewer",), privacy="anonymous"
    )
    assert (await _late_mark(client, world)).status_code == 201
    [push] = await missed_pushes(engine, "resolved")
    assert set(push.payload) == {"v", "t", "a", "p"}


async def test_a_mark_after_an_alert_that_is_now_off_still_clears_it_for_relatives(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await _alerted(client, engine, maker, settings)
    await sql(
        engine,
        "UPDATE profiles SET missed_alerts_enabled = false WHERE id = :p",
        p=uuid.UUID(world.profile_id),
    )
    assert (await _late_mark(client, world)).status_code == 201
    assert len(await missed_pushes(engine, "resolved")) == 1


# --- races (the journal lock orders a late mark against a tick) ----------------------------


async def _waiters(engine: AsyncEngine, count: int) -> None:
    """Return once ``count`` sessions wait for an advisory lock (no sleeping on a timer)."""
    for _ in range(2000):
        async with engine.connect() as conn:
            waiting = (
                await conn.execute(
                    text(
                        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted"
                    )
                )
            ).scalar_one()
        if waiting >= count:
            return
        await asyncio.sleep(0.005)
    raise AssertionError("the expected sessions never queued for the lock")


async def test_a_late_taken_that_commits_before_the_batch_reads_means_no_alert(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine)
    await set_watermark(engine, at(8, 25))
    async with maker() as holder:
        await lock_journal(holder, [uuid.UUID(world.owner.id)])
        ticking = asyncio.create_task(detect_missed_doses(maker, settings, at(8, 35)))
        await _waiters(engine, 1)  # the tick's batch waits for the owner's lock
        await holder.execute(
            text(
                "INSERT INTO dose_events (id, profile_id, medication_id, occurrence_key, type, "
                "at, recorded_at) VALUES (:id, :p, :m, :k, 'taken', :at, :at)"
            ),
            {
                "id": uuid.uuid4(),
                "p": uuid.UUID(world.profile_id),
                "m": uuid.UUID(world.medication_id),
                "k": world.key(),
                "at": at(8, 28),
            },
        )
        await holder.commit()
    report = await ticking
    assert report.alerts == 0
    assert await alert_rows(engine) == []


async def test_a_late_taken_that_waits_behind_the_batch_resolves_the_alert(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine)
    await set_watermark(engine, at(8, 25))
    async with maker() as holder:
        await lock_journal(holder, [uuid.UUID(world.owner.id)])
        ticking = asyncio.create_task(detect_missed_doses(maker, settings, at(8, 35)))
        await _waiters(engine, 1)
        marking = asyncio.create_task(_late_mark(client, world))
        await _waiters(engine, 2)  # the tick queued first, the mark behind it
        await holder.rollback()
    report = await ticking
    assert (await marking).status_code == 201
    assert report.alerts == 1
    [alert] = await alert_rows(engine)
    assert alert.resolved_at is not None
    assert len(await missed_pushes(engine, "resolved")) == 1


async def test_a_deletion_request_committed_before_the_batch_locks_means_no_alert(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine)
    await set_watermark(engine, at(8, 25))
    async with maker() as holder:
        await lock_journal(holder, [uuid.UUID(world.owner.id)])
        ticking = asyncio.create_task(detect_missed_doses(maker, settings, at(8, 35)))
        await _waiters(engine, 1)
        await holder.execute(
            text(
                "UPDATE users SET deletion_requested_at = now(), "
                "erase_after = now() + interval '30 days' WHERE id = :u"
            ),
            {"u": uuid.UUID(world.owner.id)},
        )
        await holder.commit()
    report = await ticking
    assert report.alerts == 0
    assert await alert_rows(engine) == []
