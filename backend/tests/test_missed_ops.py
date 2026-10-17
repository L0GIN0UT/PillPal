"""Operations around the detector: invalid data, logs, retention, the worker job (ADR 0007 §6)."""

from __future__ import annotations

import uuid
from datetime import timedelta

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.config import Settings
from app.worker import WorkerSettings
from tests.conftest import FakeClock
from tests.detector_helpers import (
    alert_rows,
    at,
    check_window,
    insert_event,
    make_world,
    missed_pushes,
    set_watermark,
    sql,
)
from tests.grace_helpers import count, run_retention
from tests.push_outbox_helpers import fake_senders
from tests.worker_helpers import run_burst

Maker = async_sessionmaker[AsyncSession]
SECRET_NAME = "Zolpidem-Synthetic-Name"


async def test_an_invalid_rule_is_skipped_and_logged_by_id_and_code_only(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: Maker,
    settings: Settings,
    capsys: pytest.CaptureFixture[str],
) -> None:
    broken = await make_world(client, engine, medication={"name": SECRET_NAME})
    # Valid JSON shape for the table's CHECK, but not a valid rule: no times for a daily rule.
    await sql(
        engine,
        "UPDATE schedules SET rule = CAST(:rule AS jsonb) WHERE id = :s",
        rule='{"v": 1, "kind": "daily", "start_date": "2026-10-01", "times": [], "note": "SECRET"}',
        s=uuid.UUID(broken.schedule_id),
    )
    healthy = await make_world(client, engine)
    report = await check_window(maker, engine, settings, at(8, 30))
    assert report.alerts == 1  # the healthy profile is alerted; the broken one is skipped
    assert [r.occurrence_key for r in await alert_rows(engine)] == [healthy.key()]
    out = capsys.readouterr().out
    assert '"event": "detector_invalid_rule"' in out
    assert broken.schedule_id in out
    assert '"error_code": "invalid_rule"' in out
    assert "SECRET" not in out
    assert "start_date" not in out


async def test_an_unknown_zone_is_skipped_and_logged_by_id_and_code_only(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: Maker,
    settings: Settings,
    capsys: pytest.CaptureFixture[str],
) -> None:
    world = await make_world(client, engine)
    await sql(
        engine,
        "UPDATE profiles SET timezone = 'Mars/Olympus' WHERE id = :p",
        p=uuid.UUID(world.profile_id),
    )
    assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 0
    out = capsys.readouterr().out
    assert '"error_code": "invalid_timezone"' in out
    assert "Mars" not in out


async def test_a_tick_logs_counts_and_ids_never_names_keys_or_rules(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: Maker,
    settings: Settings,
    capsys: pytest.CaptureFixture[str],
) -> None:
    world = await make_world(client, engine, medication={"name": SECRET_NAME, "notes": "N0TE"})
    taken = await insert_event(engine, world, "taken", at(8, 5), world.key())
    await insert_event(
        engine, world, "undo", at(8, 6), world.key(), target=taken, recorded_at=at(8, 30)
    )
    assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 1
    out = capsys.readouterr().out
    assert '"event": "detector_tick"' in out
    for forbidden in (SECRET_NAME, "N0TE", world.key(), "08:00", "daily", "start_date", "Aspirin"):
        assert forbidden not in out, forbidden


async def test_retention_deletes_alerts_after_72_hours(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    await make_world(client, engine)
    await check_window(maker, engine, settings, at(8, 30))
    assert await count(engine, "missed_dose_alerts") == 1
    detected = (await alert_rows(engine))[0].detected_at
    just_before = detected + timedelta(hours=71)
    report = await run_retention(client, just_before)
    assert report.missed_alerts_deleted == 0
    report = await run_retention(client, detected + timedelta(hours=73))
    assert report.missed_alerts_deleted == 1
    assert await count(engine, "missed_dose_alerts") == 0


def test_the_worker_runs_the_detector_every_minute() -> None:
    names = {getattr(f, "name", "") for f in WorkerSettings.functions}
    assert "detect_missed_doses" in names
    crons = {cron.name: cron for cron in WorkerSettings.cron_jobs}
    cron = crons["detect_missed_doses"]
    assert cron.second == 0
    assert cron.minute is None
    assert cron.hour is None
    assert cron.keep_result_s == 0


async def test_the_worker_job_detects_and_enqueues_delivery(
    client: AsyncClient,
    engine: AsyncEngine,
    settings: Settings,
    now: FakeClock,
) -> None:
    world = await make_world(client, engine)
    await set_watermark(engine, at(8, 25))
    now.now = at(8, 35)
    senders = fake_senders()
    result = await run_burst(settings, senders, now, "detect_missed_doses")
    assert result.jobs_complete >= 1
    assert result.jobs_failed == 0
    assert len(await alert_rows(engine)) == 1
    # The job enqueued ``deliver_pushes``, which the burst worker ran: the fake FCM got the push.
    assert len(await missed_pushes(engine)) == 1
    assert [m.payload.p for m in senders["fcm"].sent] == [uuid.UUID(world.profile_id)]
