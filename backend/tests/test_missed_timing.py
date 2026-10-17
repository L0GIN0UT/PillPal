"""Zones, windows, catch-up, one tick at a time and the cost of a batch (ADR 0007 §2, §5, §6)."""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime, timedelta

import pytest
from httpx import AsyncClient
from sqlalchemy import event, text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.config import Settings
from app.services.missed_doses import DETECTOR_LOCK_NAME, detect_missed_doses
from tests.conftest import make_settings
from tests.detector_helpers import (
    alert_rows,
    at,
    check_window,
    make_world,
    missed_pushes,
    set_watermark,
    tick,
    watermark,
)
from tests.helpers import daily_rule

Maker = async_sessionmaker[AsyncSession]


# --- time zones (D4) -----------------------------------------------------------------------


async def test_a_local_medication_uses_the_profile_zone(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine, timezone="Europe/Samara")  # UTC+4: 08:00 = 04:00Z
    assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 0
    assert (await check_window(maker, engine, settings, at(4, 30))).alerts == 1
    [alert] = await alert_rows(engine)
    assert alert.due_at == at(4, 0)
    assert alert.occurrence_key == world.key()


async def test_a_fixed_medication_uses_its_own_zone_not_the_profile_zone(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    await make_world(
        client,
        engine,
        timezone="Europe/Samara",
        medication={"tz_mode": "fixed", "fixed_tz": "Europe/Berlin"},  # CEST: 08:00 = 06:00Z
    )
    assert (await check_window(maker, engine, settings, at(4, 30))).alerts == 0
    assert (await check_window(maker, engine, settings, at(6, 30))).alerts == 1


async def test_a_dose_in_a_dst_gap_is_alerted_at_the_engine_instant(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    # 02:30 on 2026-03-29 does not exist in Berlin; the engine reads it with the offset before
    # the transition (01:30Z), so the alert is due at 02:00Z, not at 01:00Z or 03:00Z.
    rule = daily_rule(("02:30",), start="2026-03-01")
    world = await make_world(
        client,
        engine,
        rule=rule,
        medication={"tz_mode": "fixed", "fixed_tz": "Europe/Berlin"},
    )
    march = datetime(2026, 3, 29, 2, 0, tzinfo=UTC)
    assert (await check_window(maker, engine, settings, march - timedelta(minutes=20))).alerts == 0
    assert (await check_window(maker, engine, settings, march)).alerts == 1
    [alert] = await alert_rows(engine)
    assert alert.occurrence_key == f"{world.schedule_id}/2026-03-29T02:30"
    assert alert.due_at == datetime(2026, 3, 29, 1, 30, tzinfo=UTC)


# --- windows and catch-up -----------------------------------------------------------------


async def test_downtime_is_caught_up_in_windows_of_at_most_ten_minutes_without_duplicates(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine, times=("08:00", "08:20", "08:40", "09:10"))
    await set_watermark(engine, at(8, 0))
    now = at(10, 0)  # two hours of downtime
    seen: list[timedelta] = []
    total = 0
    for _ in range(30):
        report = await tick(maker, settings, now)
        if report.window is None:
            break
        seen.append(report.window.end - report.window.start)
        total += report.alerts
    assert max(seen) <= timedelta(minutes=10)
    assert await watermark(engine) == now
    keys = [row.occurrence_key for row in await alert_rows(engine)]
    assert sorted(keys) == sorted(world.key(t) for t in ("08:00", "08:20", "08:40", "09:10"))
    assert total == 4
    assert len(await missed_pushes(engine)) == 4


async def test_downtime_over_six_hours_skips_the_oldest_and_counts_it(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: Maker,
    settings: Settings,
    capsys: pytest.CaptureFixture[str],
) -> None:
    world = await make_world(client, engine, times=("01:00", "07:00"))
    await set_watermark(engine, at(0, 0))
    now = at(12, 0)  # 12 h of downtime: the first 6 h are skipped
    for _ in range(40):
        report = await tick(maker, settings, now)
        if report.window is None:
            break
    keys = [row.occurrence_key for row in await alert_rows(engine)]
    assert keys == [world.key("07:00")]  # 01:00 fell into the skipped span
    out = capsys.readouterr().out
    assert '"event": "detector_gap_skipped"' in out
    assert '"skipped_seconds": 21600' in out
    assert world.schedule_id not in out


async def test_a_gap_is_reported_once_and_never_logged_again(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: Maker,
    settings: Settings,
    capsys: pytest.CaptureFixture[str],
) -> None:
    await make_world(client, engine)
    await set_watermark(engine, at(0, 0))
    first = await tick(maker, settings, at(12, 0))
    second = await tick(maker, settings, at(12, 1))
    assert first.skipped_seconds == 6 * 3600
    assert second.skipped_seconds == 0
    assert capsys.readouterr().out.count("detector_gap_skipped") == 1


# --- one tick at a time -------------------------------------------------------------------


async def test_a_tick_is_skipped_while_another_holds_the_detector_lock(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    await make_world(client, engine)
    await set_watermark(engine, at(8, 25))
    async with engine.connect() as holder:
        await holder.execute(
            text("SELECT pg_advisory_lock(hashtextextended(:name, 0))"),
            {"name": DETECTOR_LOCK_NAME},
        )
        skipped = await detect_missed_doses(maker, settings, at(8, 35))
        assert skipped.ran is False
        assert await alert_rows(engine) == []
        assert await watermark(engine) == at(8, 25)  # untouched
        await holder.execute(
            text("SELECT pg_advisory_unlock(hashtextextended(:name, 0))"),
            {"name": DETECTOR_LOCK_NAME},
        )
    ran = await detect_missed_doses(maker, settings, at(8, 35))
    assert ran.ran is True
    assert ran.alerts == 1


async def test_concurrent_ticks_produce_one_set_of_alerts_and_pushes(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    await make_world(client, engine, relatives=("viewer", "editor"))
    await set_watermark(engine, at(8, 25))
    reports = await asyncio.gather(
        *(detect_missed_doses(maker, settings, at(8, 35)) for _ in range(4))
    )
    assert sum(r.alerts for r in reports) == 1
    assert len(await alert_rows(engine)) == 1
    assert len(await missed_pushes(engine)) == 2


async def test_the_lock_is_released_after_a_tick(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    await make_world(client, engine)
    await set_watermark(engine, at(8, 25))
    assert (await detect_missed_doses(maker, settings, at(8, 35))).ran
    assert (await detect_missed_doses(maker, settings, at(8, 36))).ran


# --- batches ------------------------------------------------------------------------------


async def test_profiles_are_processed_in_batches_and_the_watermark_moves_last(
    client: AsyncClient, engine: AsyncEngine, maker: Maker
) -> None:
    for _ in range(3):
        await make_world(client, engine)
    small = make_settings(detector_profile_batch=1)
    await set_watermark(engine, at(8, 25))
    report = await detect_missed_doses(maker, small, at(8, 35))
    assert report.batches == 3
    assert report.alerts == 3
    assert await watermark(engine) == at(8, 35)


async def test_a_failing_batch_leaves_the_watermark_and_a_rerun_adds_only_the_rest(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: Maker,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.services import missed_doses

    for _ in range(3):
        await make_world(client, engine)
    small = make_settings(detector_profile_batch=1)
    real = missed_doses.process_batch
    calls = 0

    async def flaky(*args: object, **kwargs: object) -> object:
        nonlocal calls
        calls += 1
        if calls == 2:
            raise RuntimeError("boom")
        return await real(*args, **kwargs)  # type: ignore[arg-type]

    monkeypatch.setattr(missed_doses, "process_batch", flaky)
    await set_watermark(engine, at(8, 25))
    with pytest.raises(RuntimeError):
        await detect_missed_doses(maker, small, at(8, 35))
    assert await watermark(engine) == at(8, 25)  # not moved: the whole window is retried
    assert len(await alert_rows(engine)) == 1
    monkeypatch.setattr(missed_doses, "process_batch", real)
    report = await detect_missed_doses(maker, small, at(8, 35))
    assert report.alerts == 2  # the first profile's alert already exists
    assert len(await alert_rows(engine)) == 3
    assert len(await missed_pushes(engine)) == 3


async def _statements_of_a_tick(
    engine: AsyncEngine, maker: Maker, settings: Settings, now: datetime
) -> int:
    count = 0

    def counter(*_: object) -> None:
        nonlocal count
        count += 1

    sync_engine = engine.sync_engine
    event.listen(sync_engine, "before_cursor_execute", counter)
    try:
        await detect_missed_doses(maker, settings, now)
    finally:
        event.remove(sync_engine, "before_cursor_execute", counter)
    return count


async def test_the_statements_of_a_batch_do_not_grow_with_its_profiles(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    await make_world(client, engine, managed=True, relatives=("guardian", "viewer"))
    await make_world(client, engine, relatives=("viewer",), privacy="anonymous")
    await set_watermark(engine, at(8, 25))
    few = await _statements_of_a_tick(engine, maker, settings, at(8, 35))
    assert len(await alert_rows(engine)) == 2

    await engine_cleanup(engine)
    for index in range(10):
        await make_world(
            client,
            engine,
            managed=bool(index % 2),
            relatives=("guardian", "viewer") if index % 2 else ("viewer", "editor"),
            privacy=("shared", "hidden", "anonymous")[index % 3],
        )
    await set_watermark(engine, at(8, 25))
    many = await _statements_of_a_tick(engine, maker, settings, at(8, 35))
    assert len(await alert_rows(engine)) == 10
    assert many == few


async def engine_cleanup(engine: AsyncEngine) -> None:
    async with engine.begin() as conn:
        await conn.execute(text("DELETE FROM push_outbox"))
        await conn.execute(text("DELETE FROM missed_dose_alerts"))
        await conn.execute(text("DELETE FROM profile_grants"))
