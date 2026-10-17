"""Review findings of PR #18: events of other profiles, send-time privacy of alerts, lock order,
lock timeout, moved owners, clock skew, the enable flag and the failure counter."""

from __future__ import annotations

import asyncio
import uuid
from datetime import timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app import worker
from app.config import Settings
from app.services import missed_batch
from app.services.changes import held_owner_locks, lock_journal
from app.services.missed_doses import detect_missed_doses
from tests.conftest import FakeClock, make_settings
from tests.detector_helpers import (
    DAY,
    alert_rows,
    at,
    check_window,
    insert_event,
    make_world,
    missed_pushes,
    set_watermark,
    sql,
    watermark,
)
from tests.helpers import register
from tests.push_outbox_helpers import deliver, fake_senders, outbox_rows

Maker = async_sessionmaker[AsyncSession]


# --- 1. one profile's events never decide another profile's alert ----------------------------


async def _foreign_event(client: AsyncClient, attacker: Any, key: str, **extra: Any) -> Any:
    body = {
        "id": str(uuid.uuid4()),
        "medication_id": attacker.medication_id,
        "type": "taken",
        "at": f"{DAY}T00:30:00Z",
        "occurrence_key": key,
        **extra,
    }
    return await client.post(
        "/v1/dose-events", json=body, headers={**attacker.owner.headers, "X-Device-ID": "x"}
    )


async def test_a_foreign_profiles_taken_does_not_suppress_the_alert(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    victim = await make_world(client, engine)
    attacker = await make_world(client, engine)
    # Already refused at write time; a legacy or direct row must not matter to the detector either.
    await insert_event(engine, attacker, "taken", at(0, 30), victim.key())
    await check_window(maker, engine, settings, at(8, 30))
    assert victim.key() in [r.occurrence_key for r in await alert_rows(engine)]


async def test_a_foreign_profiles_snooze_does_not_move_the_alert(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    victim = await make_world(client, engine)
    attacker = await make_world(client, engine)
    await insert_event(engine, attacker, "snoozed", at(8, 10), victim.key(), snooze_until=at(11, 0))
    await check_window(maker, engine, settings, at(8, 30))
    assert victim.key() in [r.occurrence_key for r in await alert_rows(engine)]


async def test_a_foreign_undo_does_not_reopen_nor_cancel(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    victim = await make_world(client, engine)
    attacker = await make_world(client, engine)
    mark = await insert_event(engine, victim, "taken", at(8, 5), victim.key())
    await insert_event(engine, attacker, "undo", at(8, 6), victim.key(), target=mark)
    # The undo lives in the attacker's profile, so it is not part of the victim's history.
    await check_window(maker, engine, settings, at(8, 30))
    keys = [r.occurrence_key for r in await alert_rows(engine)]
    assert keys == [attacker.key()]  # the victim's dose stays marked


async def test_a_foreign_schedule_key_in_the_attackers_own_profile_leaves_the_victim_alone(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    victim = await make_world(client, engine)
    attacker = await make_world(client, engine)
    # The write is accepted like one with any unknown schedule id (no existence oracle) ...
    resp = await _foreign_event(client, attacker, victim.key())
    unknown = await _foreign_event(client, attacker, f"{uuid.uuid4()}/{DAY}T08:00")
    assert resp.status_code == unknown.status_code == 201
    # ... and it lives in the attacker's history only.
    await check_window(maker, engine, settings, at(8, 30))
    assert victim.key() in [r.occurrence_key for r in await alert_rows(engine)]


# --- 2. send-time privacy of missed / resolved pushes ----------------------------------------


async def _queued(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings, **kw: Any
) -> Any:
    world = await make_world(client, engine, **kw)
    assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 1
    return world


async def _deliver(maker: Maker, settings: Settings) -> tuple[Any, Any]:
    clock = FakeClock()
    clock.now = at(8, 36)
    senders = fake_senders()
    await deliver(maker, settings, senders, clock)
    return senders, clock


async def test_an_anonymous_push_is_dropped_when_the_medication_becomes_hidden(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await _queued(
        client,
        engine,
        maker,
        settings,
        managed=True,
        relatives=("guardian", "viewer"),
        privacy="anonymous",
    )
    await sql(
        engine,
        "UPDATE medications SET privacy = 'hidden' WHERE id = :m",
        m=uuid.UUID(world.medication_id),
    )
    senders, _ = await _deliver(maker, settings)
    rows = {str(r.recipient_user_id): r for r in await outbox_rows(engine)}
    assert rows[world.relatives["viewer"].id].status == "dropped"
    assert rows[world.relatives["viewer"].id].last_error_code == "access_changed"
    assert rows[world.relatives["guardian"].id].status == "sent"
    assert len(senders["fcm"].sent) == 1


async def test_a_push_with_the_medication_is_dropped_when_it_becomes_anonymous(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await _queued(client, engine, maker, settings, relatives=("viewer",))
    await sql(
        engine,
        "UPDATE medications SET privacy = 'anonymous' WHERE id = :m",
        m=uuid.UUID(world.medication_id),
    )
    await _deliver(maker, settings)
    [row] = await outbox_rows(engine)
    assert (row.status, row.last_error_code) == ("dropped", "access_changed")


async def test_an_anonymous_push_still_goes_out_while_the_medication_stays_anonymous(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    await _queued(client, engine, maker, settings, relatives=("viewer",), privacy="anonymous")
    senders, _ = await _deliver(maker, settings)
    assert len(senders["fcm"].sent) == 1


async def test_a_missed_push_is_dropped_when_the_grantee_mutes_alerts_before_sending(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await _queued(client, engine, maker, settings, relatives=("viewer", "editor"))
    await sql(
        engine,
        "UPDATE profile_grants SET notify_missed = false WHERE grantee_user_id = :u",
        u=uuid.UUID(world.relatives["viewer"].id),
    )
    senders, _ = await _deliver(maker, settings)
    rows = {str(r.recipient_user_id): r.status for r in await outbox_rows(engine)}
    assert rows == {world.relatives["viewer"].id: "dropped", world.relatives["editor"].id: "sent"}
    assert len(senders["fcm"].sent) == 1


async def test_a_resolved_push_follows_the_same_send_time_rule(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await _queued(client, engine, maker, settings, relatives=("viewer",))
    resp = await client.post(
        "/v1/dose-events",
        json={
            "id": str(uuid.uuid4()),
            "medication_id": world.medication_id,
            "type": "taken",
            "at": "2026-10-17T00:30:00Z",
            "occurrence_key": world.key(),
        },
        headers=world.owner.headers,
    )
    assert resp.status_code == 201, resp.text
    await sql(
        engine,
        "UPDATE medications SET privacy = 'hidden' WHERE id = :m",
        m=uuid.UUID(world.medication_id),
    )
    await _deliver(maker, settings)
    assert {r.status for r in await outbox_rows(engine)} == {"dropped"}


# --- 3. lock order is guaranteed by a plpgsql function ---------------------------------------


async def _hash(engine: AsyncEngine, owner: uuid.UUID) -> int:
    async with engine.connect() as conn:
        return int(
            (
                await conn.execute(text("SELECT hashtextextended(:o, 0)"), {"o": str(owner)})
            ).scalar_one()
        )


async def _granted(engine: AsyncEngine, key: int) -> bool:
    async with engine.connect() as conn:
        row = (
            await conn.execute(
                text(
                    "SELECT bool_or(granted) FROM pg_locks WHERE locktype = 'advisory' "
                    "AND ((classid::bigint << 32) | objid::bigint) = :k"
                ),
                {"k": key},
            )
        ).scalar_one()
    return bool(row)


async def _waiting(engine: AsyncEngine) -> None:
    for _ in range(2000):
        async with engine.connect() as conn:
            n = (
                await conn.execute(
                    text("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND NOT granted")
                )
            ).scalar_one()
        if n:
            return
        await asyncio.sleep(0.005)
    raise AssertionError("nobody waits")


@pytest.mark.parametrize("reverse", [False, True])
async def test_owner_locks_are_taken_in_hash_order_whatever_the_input_order(
    engine: AsyncEngine, maker: Maker, reverse: bool
) -> None:
    owners = [uuid.uuid4() for _ in range(3)]
    keys = {o: await _hash(engine, o) for o in owners}
    low, mid, high = sorted(owners, key=lambda o: keys[o])
    async with maker() as holder:
        await lock_journal(holder, [mid])
        async with maker() as caller:
            order = [high, mid, low] if reverse else [low, mid, high]
            task = asyncio.create_task(lock_journal(caller, [*order, low]))  # a duplicate is fine
            await _waiting(engine)
            assert await _granted(engine, keys[low])  # taken before it blocked on the middle one
            assert not (await _ungranted_for(engine, keys[high]))
            await holder.rollback()
            await task
            await caller.rollback()


async def _ungranted_for(engine: AsyncEngine, key: int) -> bool:
    """Whether any session holds or waits for ``key`` as a *granted* lock (high must be free)."""
    return await _granted(engine, key)


# --- 4. lock timeout --------------------------------------------------------------------------


async def test_a_batch_that_cannot_get_its_locks_fails_the_tick_and_the_window_replays(
    client: AsyncClient, engine: AsyncEngine, maker: Maker
) -> None:
    world = await make_world(client, engine)
    quick = make_settings(detector_lock_timeout_ms=200)
    await set_watermark(engine, at(8, 25))
    async with maker() as holder:
        await lock_journal(holder, [uuid.UUID(world.owner.id)])
        with pytest.raises(DBAPIError):
            await detect_missed_doses(maker, quick, at(8, 35))
    assert await watermark(engine) == at(8, 25)
    assert (await detect_missed_doses(maker, quick, at(8, 35))).alerts == 1


def test_the_batch_size_is_capped_by_the_lock_table() -> None:
    with pytest.raises(ValueError, match="detector_profile_batch"):
        make_settings(detector_profile_batch=1001)


# --- 5. an owner change between the page and the lock ----------------------------------------


async def test_a_profile_handed_over_between_page_and_lock_is_still_processed(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: Maker,
    settings: Settings,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    world = await make_world(client, engine, managed=True, relatives=("guardian",))
    new_owner = await register(client)
    await set_watermark(engine, at(8, 25))
    locked_owners: list[set[uuid.UUID]] = []
    real_lock = missed_batch.lock_journal

    async def recording(session: AsyncSession, owners: Any) -> None:
        await real_lock(session, owners)
        locked_owners.append(set(held_owner_locks(session)))

    monkeypatch.setattr(missed_batch, "lock_journal", recording)
    async with maker() as holder:
        await lock_journal(holder, [uuid.UUID(world.owner.id)])
        ticking = asyncio.create_task(detect_missed_doses(maker, settings, at(8, 35)))
        await _waiting(engine)
        await holder.execute(
            text("UPDATE profiles SET owner_user_id = :n WHERE id = :p"),
            {"n": uuid.UUID(new_owner.id), "p": uuid.UUID(world.profile_id)},
        )
        await holder.commit()
    report = await ticking
    assert report.alerts == 1
    assert len(await alert_rows(engine)) == 1
    assert locked_owners == [{uuid.UUID(world.owner.id)}, {uuid.UUID(new_owner.id)}]


# --- 6. clock skew between the writer and the detector ---------------------------------------


async def test_an_undo_recorded_just_before_the_window_by_a_slow_clock_still_alerts(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine)
    taken = await insert_event(engine, world, "taken", at(8, 5), world.key())
    assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 0
    # recorded_at is from the writer's clock, 30 s behind the detector's window start
    await insert_event(
        engine,
        world,
        "undo",
        at(8, 6),
        world.key(),
        target=taken,
        recorded_at=at(9, 0) - timedelta(seconds=30),
    )
    await set_watermark(engine, at(9, 0))
    assert (await detect_missed_doses(maker, settings, at(9, 10))).alerts == 1


async def test_an_undo_older_than_the_skew_margin_is_left_alone(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine)
    taken = await insert_event(engine, world, "taken", at(8, 5), world.key())
    await insert_event(
        engine,
        world,
        "undo",
        at(8, 6),
        world.key(),
        target=taken,
        recorded_at=at(9, 0) - timedelta(seconds=settings.detector_skew_margin_seconds + 60),
    )
    await set_watermark(engine, at(9, 0))
    assert (await detect_missed_doses(maker, settings, at(9, 10))).alerts == 0


# --- 8. the enable flag and the failure counter ----------------------------------------------


async def test_the_worker_job_does_nothing_while_the_detector_is_disabled(
    client: AsyncClient, engine: AsyncEngine, maker: Maker
) -> None:
    await make_world(client, engine)
    await set_watermark(engine, at(8, 25))
    ctx = {
        "maker": maker,
        "settings": make_settings(detector_enabled=False),
        "now": lambda: at(8, 35),
    }
    await worker._detect_missed_doses(ctx)
    assert await alert_rows(engine) == []
    assert await watermark(engine) == at(8, 25)


def test_the_detector_is_off_by_default() -> None:
    assert make_settings().detector_enabled is False


async def test_consecutive_failed_ticks_are_counted_in_the_log(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    async def boom(*args: object, **kwargs: object) -> None:
        raise RuntimeError("sql with SECRET")

    monkeypatch.setattr(worker, "detect_missed_doses", boom)
    ctx: dict[str, Any] = {
        "maker": None,
        "settings": make_settings(detector_enabled=True),
        "now": lambda: at(8, 35),
    }
    for _ in range(2):
        with pytest.raises(RuntimeError):
            await worker._detect_missed_doses(ctx)
    out = capsys.readouterr().out
    assert '"consecutive_failures": 1' in out
    assert '"consecutive_failures": 2' in out
    assert "SECRET" not in out


# keep the helper imports used
_ = (missed_pushes,)
