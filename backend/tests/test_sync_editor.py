"""Sync push by editors: allowed writes and the editor rules (ADR 0006 §6)."""

from __future__ import annotations

import uuid

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import daily_rule
from tests.sync_editor_helpers import (
    at,
    journal_scope,
    m,
    med,
    world,
)
from tests.sync_helpers import (
    outcome,
    push_as,
    sync_all,
)

# --- applied: shared medications and schedules ----------------------------------------------


async def test_an_editor_updates_a_shared_medication_and_it_is_journaled_in_the_scope(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    w = await world(client)
    shared = w.levels["shared"]
    results = await push_as(
        client,
        w.editor,
        [m("medication", "upsert", shared.medication, med(w.pid))],
        device="editor-phone",
    )
    assert outcome(results[0]) == ("applied", None)
    seen = await sync_all(client, w.owner)
    changed = seen.by_id(shared.medication)
    assert changed["data"]["name"] == "Edited by relative"
    assert changed["updated_by_device"] == "editor-phone"
    assert await journal_scope(engine, shared.medication) == {w.pid}


async def test_an_editor_creates_a_shared_medication_with_a_schedule_in_one_batch(
    client: AsyncClient,
) -> None:
    w = await world(client)
    new_med, new_sched = str(uuid.uuid4()), str(uuid.uuid4())
    results = await push_as(
        client,
        w.editor,
        [
            m("medication", "upsert", new_med, med(w.pid)),
            m("schedule", "upsert", new_sched, {"medication_id": new_med, "rule": daily_rule()}),
        ],
    )
    assert [outcome(r) for r in results] == [("applied", None), ("applied", None)]
    owner_view = await client.get(f"/v1/medications/{new_med}", headers=w.owner.headers)
    assert owner_view.json()["privacy"] == "shared"
    assert (
        await client.get(f"/v1/schedules/{new_sched}", headers=w.owner.headers)
    ).status_code == 200


async def test_an_editor_updates_a_schedule_of_a_shared_medication(client: AsyncClient) -> None:
    w = await world(client)
    shared = w.levels["shared"]
    rule = daily_rule(("09:30",))
    results = await push_as(
        client,
        w.editor,
        [
            m(
                "schedule",
                "upsert",
                shared.schedule,
                {"medication_id": shared.medication, "rule": rule},
            )
        ],
    )
    assert outcome(results[0]) == ("applied", None)
    stored = await client.get(f"/v1/schedules/{shared.schedule}", headers=w.owner.headers)
    assert stored.json()["rule"]["times"][0]["time"] == "09:30"


# --- rule 5: privacy is the owner's ---------------------------------------------------------------


@pytest.mark.parametrize("target", ["anonymous", "hidden"])
async def test_an_editor_cannot_change_the_privacy_of_a_shared_medication(
    client: AsyncClient, target: str
) -> None:
    w = await world(client)
    shared = w.levels["shared"]
    results = await push_as(
        client, w.editor, [m("medication", "upsert", shared.medication, med(w.pid, privacy=target))]
    )
    assert outcome(results[0]) == ("rejected", "forbidden_field")
    current = results[0]["current"]
    assert current["op"] == "upsert"
    assert current["data"]["privacy"] == "shared"
    assert current["data"]["name"] == "Synthetic Tablet"  # shared: the full medication
    assert current["updated_by_device"] is None  # projected envelope
    stored = await client.get(f"/v1/medications/{shared.medication}", headers=w.owner.headers)
    assert stored.json()["privacy"] == "shared"


@pytest.mark.parametrize("privacy", ["anonymous", "hidden"])
async def test_an_editor_cannot_create_a_medication_that_is_not_shared(
    client: AsyncClient, privacy: str
) -> None:
    w = await world(client)
    new_med = str(uuid.uuid4())
    results = await push_as(
        client, w.editor, [m("medication", "upsert", new_med, med(w.pid, privacy=privacy))]
    )
    assert outcome(results[0]) == ("rejected", "forbidden_field")
    assert results[0]["current"] is None
    assert (
        await client.get(f"/v1/medications/{new_med}", headers=w.owner.headers)
    ).status_code == 404


async def test_the_privacy_check_comes_before_last_write_wins(client: AsyncClient) -> None:
    w = await world(client)
    shared = w.levels["shared"]
    old = m("medication", "upsert", shared.medication, med(w.pid, privacy="hidden"), seconds=-3600)
    results = await push_as(client, w.editor, [old])
    assert outcome(results[0]) == ("rejected", "forbidden_field")  # not ignored_stale


# --- rule 3: dose events belong to full-access roles (D3) -------------------------------------


async def test_every_kind_of_dose_event_is_forbidden_to_an_editor(client: AsyncClient) -> None:
    w = await world(client)
    shared = w.levels["shared"]
    base = {"medication_id": shared.medication, "at": at(0)}
    new_ids = [str(uuid.uuid4()) for _ in range(4)]
    batch = [
        m("dose_event", "upsert", new_ids[0], {**base, "type": "taken"}),
        m("dose_event", "upsert", new_ids[1], {**base, "type": "skipped"}),
        m(
            "dose_event",
            "upsert",
            new_ids[2],
            {**base, "type": "snoozed", "snooze_until": at(600)},
        ),
        m(
            "dose_event",
            "upsert",
            new_ids[3],
            {**base, "type": "undo", "target_event_id": shared.event},
        ),
    ]
    results = await push_as(client, w.editor, batch)
    assert {outcome(r) for r in results} == {("rejected", "forbidden")}
    listing = await client.get("/v1/dose-events", headers=w.owner.headers)
    assert {e["id"] for e in listing.json()["items"]} == {lv.event for lv in w.levels.values()}


async def test_forbidden_on_an_existing_dose_event_shows_it_without_note_or_device(
    client: AsyncClient,
) -> None:
    w = await world(client)
    shared = w.levels["shared"]
    payload = {"medication_id": shared.medication, "type": "taken", "at": at(0)}
    results = await push_as(client, w.editor, [m("dose_event", "upsert", shared.event, payload)])
    assert outcome(results[0]) == ("rejected", "forbidden")
    current = results[0]["current"]["data"]
    assert current["id"] == shared.event
    assert "note" not in current
    assert "device_id" not in current


# --- rule 4: no deletes (D3) ------------------------------------------------------------------


async def test_an_editor_cannot_delete_a_medication_or_a_schedule(client: AsyncClient) -> None:
    w = await world(client)
    shared = w.levels["shared"]
    results = await push_as(
        client,
        w.editor,
        [m("medication", "delete", shared.medication), m("schedule", "delete", shared.schedule)],
    )
    assert [outcome(r) for r in results] == [("rejected", "forbidden")] * 2
    assert results[0]["current"]["data"]["id"] == shared.medication
    assert results[1]["current"]["data"]["id"] == shared.schedule
    assert (
        await client.get(f"/v1/medications/{shared.medication}", headers=w.owner.headers)
    ).status_code == 200


# --- rule 2: the profile is read-only for projected roles -------------------------------------


async def test_profile_writes_by_an_editor_are_read_only_with_the_projected_profile(
    client: AsyncClient,
) -> None:
    w = await world(client)
    data = {"kind": "self", "display_name": "Hijacked", "timezone": "UTC"}
    results = await push_as(
        client,
        w.editor,
        [m("profile", "upsert", w.pid, data), m("profile", "delete", w.pid)],
    )
    assert [outcome(r) for r in results] == [("rejected", "read_only")] * 2
    current = results[0]["current"]["data"]
    assert set(current) == {"id", "kind", "display_name", "timezone"}
    profile = await client.get(f"/v1/profiles/{w.pid}", headers=w.owner.headers)
    assert profile.json()["display_name"] != "Hijacked"
