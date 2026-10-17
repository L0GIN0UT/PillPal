"""The missed-dose detector tick (ADR 0007): what is alerted, when, and exactly once."""

from __future__ import annotations

import uuid
from datetime import timedelta

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.config import Settings
from tests.detector_helpers import (
    alert_rows,
    at,
    check_window,
    insert_event,
    make_world,
    missed_pushes,
    recipients_of_pushes,
    register_token,
    set_watermark,
    sql,
    tick,
    watermark,
)

Maker = async_sessionmaker[AsyncSession]


async def test_an_unmarked_dose_alerts_once_per_recipient_token_and_never_again(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine, relatives=("viewer", "editor"))
    await register_token(
        client, world.relatives["viewer"], "dev-2"
    )  # a second device of the viewer

    report = await check_window(maker, engine, settings, at(8, 30))

    assert report.alerts == 1
    [alert] = await alert_rows(engine)
    assert alert.occurrence_key == world.key()
    assert alert.due_at == at(8, 0)
    assert alert.variant == "missed"
    assert alert.resolved_at is None
    pushes = await missed_pushes(engine)
    assert len(pushes) == 3  # viewer x 2 tokens + editor x 1 token
    assert recipients_of_pushes(pushes) == sorted(
        [world.relatives["viewer"].id] * 2 + [world.relatives["editor"].id]
    )
    assert pushes[0].payload == {
        "v": 1,
        "t": "missed",
        "a": str(alert.id),
        "p": world.profile_id,
        "m": world.medication_id,
    }
    # The next tick and a replay of the same window add nothing.
    again = await tick(maker, settings, at(8, 40))
    replay = await check_window(maker, engine, settings, at(8, 30))
    assert (again.alerts, replay.alerts) == (0, 0)
    assert len(await alert_rows(engine)) == 1
    assert len(await missed_pushes(engine)) == 3


async def test_the_alert_waits_for_the_grace_period(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    await make_world(client, engine)
    await set_watermark(engine, at(8, 25))
    assert (await tick(maker, settings, at(8, 30))).alerts == 0  # [08:25, 08:30): end exclusive
    assert (await tick(maker, settings, at(8, 31))).alerts == 1  # [08:30, 08:31)


async def test_a_dose_marked_before_the_alert_time_is_not_alerted(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    taken = await make_world(client, engine)
    await insert_event(engine, taken, "taken", at(8, 5), taken.key())
    assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 0
    skipped = await make_world(client, engine)
    await insert_event(engine, skipped, "skipped", at(8, 5), skipped.key())
    assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 0
    assert await alert_rows(engine) == []


async def test_an_undo_before_the_alert_time_leaves_the_dose_alerted(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine)
    taken = await insert_event(engine, world, "taken", at(8, 5), world.key())
    await insert_event(engine, world, "undo", at(8, 10), world.key(), target=taken)
    assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 1


async def test_a_late_undo_alerts_in_the_tick_that_sees_it(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine)
    taken = await insert_event(engine, world, "taken", at(8, 5), world.key())
    assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 0
    await insert_event(
        engine, world, "undo", at(8, 6), world.key(), target=taken, recorded_at=at(9, 0)
    )
    # The undo was recorded at 09:00: its own window is the one that raises the alert.
    assert (await check_window(maker, engine, settings, at(9, 0))).alerts == 1
    [alert] = await alert_rows(engine)
    assert alert.occurrence_key == world.key()
    assert (await check_window(maker, engine, settings, at(9, 0))).alerts == 0  # not twice


async def test_a_late_undo_of_an_old_occurrence_does_not_page_relatives(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine)
    taken = await insert_event(engine, world, "taken", at(8, 5), world.key())
    await insert_event(
        engine, world, "undo", at(8, 6), world.key(), target=taken, recorded_at=at(8, 0, day=19)
    )
    assert (await check_window(maker, engine, settings, at(8, 0, day=19))).alerts == 0


async def test_a_snoozed_dose_alerts_after_the_snooze_not_after_the_occurrence(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine)
    await insert_event(engine, world, "snoozed", at(8, 10), world.key(), snooze_until=at(8, 20))
    assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 0
    assert (await check_window(maker, engine, settings, at(8, 50))).alerts == 1
    [alert] = await alert_rows(engine)
    assert alert.due_at == at(8, 20)  # the final due, which the grant rule compares to


async def test_a_second_snooze_moves_the_alert_again(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine)
    await insert_event(engine, world, "snoozed", at(8, 10), world.key(), snooze_until=at(8, 20))
    await insert_event(engine, world, "snoozed", at(8, 25), world.key(), snooze_until=at(8, 40))
    assert (await check_window(maker, engine, settings, at(8, 50))).alerts == 0  # first snooze
    assert (await check_window(maker, engine, settings, at(9, 10))).alerts == 1  # latest snooze


async def test_a_snooze_marked_afterwards_is_not_alerted(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine)
    await insert_event(engine, world, "snoozed", at(8, 10), world.key(), snooze_until=at(8, 20))
    await insert_event(engine, world, "taken", at(8, 25), world.key())
    assert (await check_window(maker, engine, settings, at(8, 50))).alerts == 0


async def test_a_late_undo_of_a_snooze_alerts_the_original_due_time(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine)
    snooze = await insert_event(
        engine, world, "snoozed", at(8, 10), world.key(), snooze_until=at(10, 0)
    )
    assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 0
    await insert_event(
        engine, world, "undo", at(8, 11), world.key(), target=snooze, recorded_at=at(9, 0)
    )
    assert (await check_window(maker, engine, settings, at(9, 0))).alerts == 1
    [alert] = await alert_rows(engine)
    assert alert.due_at == at(8, 0)


async def test_every_slot_of_a_day_is_alerted_once_at_its_own_time(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine, times=("08:00", "14:00", "20:00"))
    await insert_event(engine, world, "taken", at(14, 5), world.key("14:00"))
    await set_watermark(engine, at(7, 0))
    now = at(7, 0)
    while now < at(23, 59):  # a tick every 9 minutes across the day
        now += timedelta(minutes=9)
        await tick(maker, settings, now)
    keys = sorted(row.occurrence_key for row in await alert_rows(engine))
    assert keys == sorted([world.key("08:00"), world.key("20:00")])
    assert len(await missed_pushes(engine)) == 2


async def test_a_schedule_created_after_the_occurrence_is_not_alerted(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine)
    await sql(
        engine,
        "UPDATE schedules SET created_at = :t WHERE id = :s",
        t=at(8, 20),
        s=uuid.UUID(world.schedule_id),
    )
    assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 0
    # The next day's occurrence, after the schedule exists, is alerted as usual.
    assert (await check_window(maker, engine, settings, at(8, 30, day=18))).alerts == 1


async def test_deleted_schedules_and_medications_are_not_alerted(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    gone_schedule = await make_world(client, engine)
    resp = await client.delete(
        f"/v1/schedules/{gone_schedule.schedule_id}", headers=gone_schedule.owner.headers
    )
    assert resp.status_code == 204
    gone_medication = await make_world(client, engine)
    resp = await client.delete(
        f"/v1/medications/{gone_medication.medication_id}", headers=gone_medication.owner.headers
    )
    assert resp.status_code == 204
    assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 0


async def test_a_profile_alert_threshold_is_respected(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine)
    resp = await client.patch(
        f"/v1/profiles/{world.profile_id}",
        json={"missed_alert_minutes": 60},
        headers=world.owner.headers,
    )
    assert resp.status_code == 200, resp.text
    assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 0
    assert (await check_window(maker, engine, settings, at(9, 0))).alerts == 1
    [alert] = await alert_rows(engine)
    assert alert.occurrence_key == world.key()


async def test_a_tick_moves_the_watermark_to_the_end_of_its_window_only_forward(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    await make_world(client, engine)
    await set_watermark(engine, at(8, 0))
    report = await tick(maker, settings, at(8, 3))
    assert report.window is not None
    assert await watermark(engine) == at(8, 3)
    # A clock that is behind the watermark finds nothing to do and never moves it back.
    assert (await tick(maker, settings, at(8, 1))).window is None
    assert await watermark(engine) == at(8, 3)
