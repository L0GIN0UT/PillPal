"""Sync push: what relatives cannot see, viewers and strangers (ADR 0006 §6)."""

from __future__ import annotations

import uuid

import pytest
from httpx import AsyncClient

from tests.helpers import daily_rule, register
from tests.sync_editor_helpers import (
    at,
    m,
    med,
    world,
)
from tests.sync_helpers import (
    outcome,
    push_as,
)

# --- rule 1: what the editor cannot see does not exist for them -------------------------------


@pytest.mark.parametrize("role", ["editor", "viewer"])
@pytest.mark.parametrize("level", ["anonymous", "hidden"])
async def test_writes_to_an_invisible_medication_or_its_children_look_like_missing_ones(
    client: AsyncClient, role: str, level: str
) -> None:
    w = await world(client)
    relative = w.editor if role == "editor" else w.viewer
    lv = w.levels[level]
    new_sched, new_event = str(uuid.uuid4()), str(uuid.uuid4())
    taken = {"medication_id": lv.medication, "type": "taken", "at": at(0)}
    rule = {"medication_id": lv.medication, "rule": daily_rule()}
    results = await push_as(
        client,
        relative,
        [
            m("medication", "upsert", lv.medication, med(w.pid)),
            m("schedule", "upsert", lv.schedule, rule),
            m("dose_event", "upsert", lv.event, taken),
            m("medication", "delete", lv.medication),
            m("schedule", "delete", lv.schedule),
            m("schedule", "upsert", new_sched, rule),
            m("dose_event", "upsert", new_event, taken),
        ],
    )
    assert [outcome(r) for r in results] == [
        ("rejected", "not_found"),  # an id that exists is never taken over
        ("rejected", "not_found"),
        ("rejected", "not_found"),
        ("applied", None),  # a delete is a quiet no-op, as for an id that does not exist
        ("applied", None),
        ("rejected", "parent_not_found"),  # as under a missing or a foreign parent
        ("rejected", "parent_not_found"),
    ]
    assert all(r["current"] is None for r in results)
    stored = await client.get(f"/v1/medications/{lv.medication}", headers=w.owner.headers)
    assert stored.status_code == 200  # the no-op delete deleted nothing
    assert stored.json()["name"] == "Synthetic Tablet"  # untouched
    assert (
        await client.get(f"/v1/schedules/{new_sched}", headers=w.owner.headers)
    ).status_code == 404


@pytest.mark.parametrize("role", ["editor", "viewer"])
async def test_a_hidden_parent_answers_like_a_missing_parent(
    client: AsyncClient, role: str
) -> None:
    w = await world(client)
    relative = w.editor if role == "editor" else w.viewer
    hidden = w.levels["hidden"].medication
    missing = str(uuid.uuid4())
    results = await push_as(
        client,
        relative,
        [
            m("schedule", "upsert", str(uuid.uuid4()), {"medication_id": p, "rule": daily_rule()})
            for p in (hidden, missing)
        ]
        + [m("medication", "delete", p) for p in (hidden, missing)],
    )
    assert outcome(results[0]) == outcome(results[1]) == ("rejected", "parent_not_found")
    assert outcome(results[2]) == outcome(results[3]) == ("applied", None)


async def test_an_existing_hidden_id_in_an_own_payload_is_not_found_not_a_collision(
    client: AsyncClient,
) -> None:
    w = await world(client)
    hidden = w.levels["hidden"]
    own_profile = w.editor.self_profile_id
    results = await push_as(
        client, w.editor, [m("medication", "upsert", hidden.medication, med(own_profile))]
    )
    assert outcome(results[0]) == (
        "rejected",
        "not_found",
    )  # never integrity_error / already_exists
    assert (
        await client.get(f"/v1/medications/{hidden.medication}", headers=w.editor.headers)
    ).status_code == 404


# --- viewers ----------------------------------------------------------------------------------


async def test_a_viewer_is_forbidden_on_visible_entities_and_blind_to_the_rest(
    client: AsyncClient,
) -> None:
    w = await world(client)
    shared, hidden, anon = (w.levels[k] for k in ("shared", "hidden", "anonymous"))
    results = await push_as(
        client,
        w.viewer,
        [
            m("medication", "upsert", shared.medication, med(w.pid)),
            m("schedule", "delete", shared.schedule),
            m(
                "dose_event",
                "upsert",
                str(uuid.uuid4()),
                {"medication_id": shared.medication, "type": "taken", "at": at(0)},
            ),
            m("profile", "upsert", w.pid, {"kind": "self", "display_name": "X", "timezone": "UTC"}),
            m("medication", "upsert", hidden.medication, med(w.pid)),
            m("medication", "upsert", anon.medication, med(w.pid)),
        ],
    )
    assert [outcome(r) for r in results] == [
        ("rejected", "forbidden"),
        ("rejected", "forbidden"),
        ("rejected", "forbidden"),
        ("rejected", "forbidden"),
        ("rejected", "not_found"),
        ("rejected", "not_found"),
    ]
    assert results[0]["current"]["data"]["name"] == "Synthetic Tablet"
    assert results[3]["current"]["data"]["id"] == w.pid


# --- strangers --------------------------------------------------------------------------------


async def test_a_stranger_gets_what_a_missing_id_gets(client: AsyncClient) -> None:
    w = await world(client)
    stranger = await register(client)
    shared = w.levels["shared"]
    results = await push_as(
        client,
        stranger,
        [
            m("medication", "upsert", shared.medication, med(stranger.self_profile_id)),
            m("medication", "delete", shared.medication),
            m("medication", "upsert", str(uuid.uuid4()), med(w.pid)),
            m(
                "schedule",
                "upsert",
                str(uuid.uuid4()),
                {"medication_id": shared.medication, "rule": daily_rule()},
            ),
            m(
                "dose_event",
                "upsert",
                str(uuid.uuid4()),
                {"medication_id": shared.medication, "type": "taken", "at": at(0)},
            ),
            m("profile", "delete", w.pid),
        ],
    )
    assert [outcome(r) for r in results] == [
        ("rejected", "not_found"),  # an id that exists elsewhere is never created or taken over
        ("applied", None),  # nothing visible to delete
        ("rejected", "parent_not_found"),
        ("rejected", "parent_not_found"),
        ("rejected", "parent_not_found"),
        ("applied", None),
    ]
    assert (
        await client.get(f"/v1/medications/{shared.medication}", headers=w.owner.headers)
    ).status_code == 200


# --- the gates do not break what comes after them ---------------------------------------------


async def test_an_editor_cannot_move_a_medication_to_another_profile(client: AsyncClient) -> None:
    w = await world(client)
    shared = w.levels["shared"]
    results = await push_as(
        client,
        w.editor,
        [m("medication", "upsert", shared.medication, med(w.editor.self_profile_id))],
    )
    assert outcome(results[0]) == ("rejected", "immutable_field")


async def test_validation_errors_still_come_first_for_relatives(client: AsyncClient) -> None:
    w = await world(client)
    results = await push_as(
        client, w.editor, [m("medication", "upsert", w.levels["shared"].medication, {"nope": 1})]
    )
    assert outcome(results[0]) == ("rejected", "validation_error")
