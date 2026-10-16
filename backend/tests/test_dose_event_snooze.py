"""``snoozed`` dose events carry ``snooze_until`` (ADR 0001 §7, migration 0002)."""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import create_medication, create_schedule, downgrade, register, run_migrations
from tests.test_dose_events import event, post_event
from tests.test_sync import mut, pull, push

AT = "2026-10-16T08:03:00+04:00"


async def test_snoozed_event_round_trips_snooze_until(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    sched = await create_schedule(client, user, med["id"])
    body = event(
        med["id"],
        type="snoozed",
        at=AT,
        snooze_until="2026-10-16T08:18:00+04:00",
        occurrence_key=f"{sched['id']}/2026-10-16T08:00",
    )

    created = await post_event(client, user, body)
    assert created.status_code == 201, created.text
    stored = created.json()
    assert stored["snooze_until"].startswith("2026-10-16T04:18:00")

    replay = await post_event(client, user, {**body, "snooze_until": "2026-10-16T04:18:00Z"})
    assert replay.status_code == 200
    assert replay.json() == stored
    other_until = await post_event(client, user, {**body, "snooze_until": "2026-10-16T04:33:00Z"})
    assert other_until.status_code == 409
    assert other_until.json()["error"]["code"] == "idempotency_conflict"

    got = await client.get(f"/v1/dose-events/{stored['id']}", headers=user.headers)
    assert got.json() == stored


async def test_other_event_types_report_null_snooze_until(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    created = await post_event(client, user, event(med["id"]))
    assert created.status_code == 201
    assert created.json()["snooze_until"] is None


@pytest.mark.parametrize(
    "overrides",
    [
        {"type": "snoozed"},  # required for snoozed
        {"type": "snoozed", "snooze_until": None},
        {"type": "taken", "snooze_until": "2026-10-16T04:18:00Z"},  # forbidden otherwise
        {"type": "skipped", "snooze_until": "2026-10-16T04:18:00Z"},
        {"type": "snoozed", "snooze_until": "2026-10-16T04:03:00Z"},  # not after `at`
        {"type": "snoozed", "snooze_until": "2026-10-16T03:00:00Z"},
        {"type": "snoozed", "snooze_until": "2026-10-17T04:03:01Z"},  # > at + 24 h
        {"type": "snoozed", "snooze_until": "2026-10-16T08:18:00"},  # naive
    ],
)
async def test_snooze_until_validation(client: AsyncClient, overrides: dict[str, Any]) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    resp = await post_event(client, user, event(med["id"], at=AT, **overrides))
    assert resp.status_code == 422, resp.text


async def test_snooze_until_may_be_exactly_24_hours_later(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    body = event(med["id"], type="snoozed", at=AT, snooze_until="2026-10-17T04:03:00Z")
    assert (await post_event(client, user, body)).status_code == 201


async def test_undo_of_a_snooze_needs_no_snooze_until(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    snoozed = await post_event(
        client, user, event(med["id"], type="snoozed", at=AT, snooze_until="2026-10-16T04:18:00Z")
    )
    undo = await post_event(
        client, user, event(med["id"], type="undo", target_event_id=snoozed.json()["id"])
    )
    assert undo.status_code == 201, undo.text
    assert undo.json()["snooze_until"] is None


async def test_snooze_until_via_sync_push_and_pull(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    good = str(uuid.uuid4())
    snoozed = {
        "medication_id": med["id"],
        "type": "snoozed",
        "at": "2026-10-01T08:00:00Z",
        "snooze_until": "2026-10-01T08:15:00Z",
    }
    results = await push(
        client,
        user,
        "phone",
        [
            mut("dose_event", "upsert", good, snoozed),
            mut("dose_event", "upsert", good, snoozed),  # replay
            mut("dose_event", "upsert", str(uuid.uuid4()), {**snoozed, "snooze_until": None}),
            mut("dose_event", "upsert", str(uuid.uuid4()), {**snoozed, "type": "taken"}),
        ],
    )
    assert [(r["status"], r["code"]) for r in results] == [
        ("applied", None),
        ("applied", None),
        ("rejected", "validation_error"),
        ("rejected", "validation_error"),
    ]
    page = await pull(client, user)
    events = [c for c in page["changes"] if c["entity"] == "dose_event"]
    assert [c["id"] for c in events] == [good]
    assert events[0]["data"]["snooze_until"].startswith("2026-10-01T08:15:00")


async def test_database_enforces_snooze_until(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    insert = (
        "INSERT INTO dose_events (id, profile_id, medication_id, type, at, snooze_until) "
        "VALUES (gen_random_uuid(), :profile, :med, :type, :at, :until)"
    )
    at = "2026-10-16T04:00:00Z"
    cases = [
        ("snoozed", None),
        ("taken", "2026-10-16T04:15:00Z"),
        ("snoozed", at),
        ("snoozed", "2026-10-17T04:00:01Z"),
    ]
    async with engine.connect() as conn:
        for type_, until in cases:
            with pytest.raises(Exception, match="snooze_until"):
                await conn.execute(
                    text(insert),
                    {
                        "profile": user.self_profile_id,
                        "med": med["id"],
                        "type": type_,
                        "at": at,
                        "until": until,
                    },
                )
            await conn.rollback()


async def test_migration_0002_downgrades_and_upgrades() -> None:
    from tests.test_config_and_migrations import _recreate_db

    url = await _recreate_db("pillpal_test_migration_0002")
    run_migrations(url, "head")
    downgrade(url, "0001_initial")
    run_migrations(url, "head")
