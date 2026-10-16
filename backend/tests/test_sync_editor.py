"""Sync push by relatives: rule order, rejection codes, projected ``current`` (ADR 0006 §6)."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import User, create_managed_profile, daily_rule, link_accounts, register
from tests.sync_helpers import (
    make_event,
    make_medication,
    make_schedule,
    outcome,
    push_as,
    sync_all,
)


def at(seconds: int = 5) -> str:
    """A client timestamp newer than anything the server stored a moment ago."""
    return (datetime.now(UTC) + timedelta(seconds=seconds)).isoformat()


def m(
    entity: str, op: str, id_: str, data: dict[str, Any] | None = None, seconds: int = 5
) -> dict[str, Any]:
    return {"entity": entity, "op": op, "id": id_, "data": data, "client_updated_at": at(seconds)}


def med(profile_id: str, **overrides: Any) -> dict[str, Any]:
    return {"profile_id": profile_id, "name": "Edited by relative", "tz_mode": "local"} | overrides


@dataclass
class Level:
    medication: str
    schedule: str
    event: str


@dataclass
class World:
    owner: User
    editor: User
    viewer: User
    levels: dict[str, Level]

    @property
    def pid(self) -> str:
        return self.owner.self_profile_id


async def world(client: AsyncClient) -> World:
    owner, editor, viewer = await register(client), await register(client), await register(client)
    await link_accounts(client, owner, editor, "editor")
    await link_accounts(client, owner, viewer, "viewer")
    levels: dict[str, Level] = {}
    for privacy in ("shared", "anonymous", "hidden"):
        mid = await make_medication(client, owner, owner.self_profile_id, privacy)
        levels[privacy] = Level(
            mid, await make_schedule(client, owner, mid), await make_event(client, owner, mid)
        )
    return World(owner, editor, viewer, levels)


async def journal_scope(engine: AsyncEngine, entity_id: str) -> set[str]:
    async with engine.connect() as conn:
        rows = await conn.execute(
            text("SELECT profile_id FROM sync_changes WHERE entity_id = :i"), {"i": entity_id}
        )
        return {str(r[0]) for r in rows}


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


# --- rule 1: what the editor cannot see does not exist for them -------------------------------


@pytest.mark.parametrize("level", ["anonymous", "hidden"])
async def test_writes_to_an_invisible_medication_or_its_children_are_not_found(
    client: AsyncClient, level: str
) -> None:
    w = await world(client)
    lv = w.levels[level]
    new_sched, new_event = str(uuid.uuid4()), str(uuid.uuid4())
    taken = {"medication_id": lv.medication, "type": "taken", "at": at(0)}
    results = await push_as(
        client,
        w.editor,
        [
            m("medication", "upsert", lv.medication, med(w.pid)),
            m("medication", "delete", lv.medication),
            m(
                "schedule",
                "upsert",
                lv.schedule,
                {"medication_id": lv.medication, "rule": daily_rule()},
            ),
            m("schedule", "delete", lv.schedule),
            m(
                "schedule",
                "upsert",
                new_sched,
                {"medication_id": lv.medication, "rule": daily_rule()},
            ),
            m("dose_event", "upsert", lv.event, taken),
            m("dose_event", "upsert", new_event, taken),
        ],
    )
    assert {outcome(r) for r in results} == {("rejected", "not_found")}
    assert all(r["current"] is None for r in results)
    stored = await client.get(f"/v1/medications/{lv.medication}", headers=w.owner.headers)
    assert stored.json()["name"] == "Synthetic Tablet"  # untouched
    assert (
        await client.get(f"/v1/schedules/{new_sched}", headers=w.owner.headers)
    ).status_code == 404


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


# --- guardians: full access, except deleting the managed profile ------------------------------


async def test_a_guardian_has_full_access_but_cannot_delete_the_managed_profile(
    client: AsyncClient,
) -> None:
    owner, guardian = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, guardian, "guardian", ward)
    hidden = await make_medication(client, owner, ward, "hidden")
    sid = await make_schedule(client, owner, hidden)
    event = str(uuid.uuid4())
    results = await push_as(
        client,
        guardian,
        [
            m("medication", "upsert", hidden, med(ward, privacy="anonymous")),
            m("schedule", "delete", sid),
            m(
                "dose_event",
                "upsert",
                event,
                {"medication_id": hidden, "type": "taken", "at": at(0)},
            ),
            m(
                "profile",
                "upsert",
                ward,
                {"kind": "managed", "display_name": "Renamed", "timezone": "UTC"},
            ),
            m("profile", "delete", ward),
        ],
    )
    assert [outcome(r) for r in results] == [
        ("applied", None),
        ("applied", None),
        ("applied", None),
        ("applied", None),
        ("rejected", "forbidden"),
    ]
    assert results[4]["current"]["data"]["display_name"] == "Renamed"  # full, not projected
    stored = await client.get(f"/v1/profiles/{ward}", headers=owner.headers)
    assert stored.status_code == 200
    gone = await push_as(client, owner, [m("profile", "delete", ward, seconds=10)])
    assert outcome(gone[0]) == ("applied", None)
    assert (await client.get(f"/v1/profiles/{ward}", headers=owner.headers)).status_code == 404


# --- convergence of owner and editor ----------------------------------------------------------


@pytest.mark.parametrize("editor_first", [True, False])
async def test_owner_and_editor_converge_whatever_the_arrival_order(
    client: AsyncClient, editor_first: bool
) -> None:
    w = await world(client)
    mid = w.levels["shared"].medication
    editor_write = m("medication", "upsert", mid, med(w.pid, name="Editor"), seconds=20)
    owner_write = m("medication", "upsert", mid, med(w.pid, name="Owner"), seconds=10)
    sequence = [(w.editor, editor_write, "e-dev"), (w.owner, owner_write, "o-dev")]
    if not editor_first:
        sequence.reverse()
    outcomes = [
        outcome((await push_as(client, who, [mut_], device=dev))[0]) for who, mut_, dev in sequence
    ]
    expected = ["applied", "ignored_stale"] if editor_first else ["applied", "applied"]
    assert [o[0] for o in outcomes] == expected
    owner_sees = (await sync_all(client, w.owner)).by_id(mid)["data"]["name"]
    editor_sees = (await sync_all(client, w.editor, {w.pid: 0})).by_id(mid)["data"]["name"]
    assert owner_sees == editor_sees == "Editor"  # the newer timestamp wins everywhere


async def test_equal_timestamps_are_broken_by_the_device_id_for_both_roles(
    client: AsyncClient,
) -> None:
    w = await world(client)
    mid = w.levels["shared"].medication
    stamp = at(30)
    owner_write = {
        **m("medication", "upsert", mid, med(w.pid, name="Owner")),
        "client_updated_at": stamp,
    }
    editor_write = {
        **m("medication", "upsert", mid, med(w.pid, name="Editor")),
        "client_updated_at": stamp,
    }
    await push_as(client, w.owner, [owner_write], device="aaa-owner")
    result = await push_as(client, w.editor, [editor_write], device="zzz-editor")
    assert outcome(result[0]) == ("applied", None)  # the larger device id wins the tie
    stale = await push_as(client, w.owner, [owner_write], device="aaa-owner")
    assert outcome(stale[0]) == ("ignored_stale", None)
    assert stale[0]["current"]["data"]["name"] == "Editor"
    assert stale[0]["current"]["updated_by_device"] == "zzz-editor"  # the owner sees the device


async def test_ignored_stale_current_is_projected_for_an_editor(client: AsyncClient) -> None:
    w = await world(client)
    mid = w.levels["shared"].medication
    await push_as(
        client,
        w.owner,
        [m("medication", "upsert", mid, med(w.pid, name="Newer"), 60)],
        device="o-dev",
    )
    stale = await push_as(
        client,
        w.editor,
        [m("medication", "upsert", mid, med(w.pid, name="Older"), 5)],
        device="e-dev",
    )
    assert outcome(stale[0]) == ("ignored_stale", None)
    assert stale[0]["current"]["data"]["name"] == "Newer"
    assert stale[0]["current"]["updated_by_device"] is None


# --- deleted scopes ----------------------------------------------------------------------


async def test_a_deleted_managed_profile_is_gone_for_guardians_but_idempotent_for_its_owner(
    client: AsyncClient,
) -> None:
    owner, guardian = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, guardian, "guardian", ward)
    mid = await make_medication(client, owner, ward)
    assert (await client.delete(f"/v1/profiles/{ward}", headers=owner.headers)).status_code == 204
    profile = {"kind": "managed", "display_name": "Zombie", "timezone": "UTC"}
    guardian_results = await push_as(
        client,
        guardian,
        [
            m("profile", "upsert", ward, profile),
            m("medication", "upsert", str(uuid.uuid4()), med(ward)),
            m("medication", "upsert", mid, med(ward)),
        ],
    )
    assert [outcome(r) for r in guardian_results] == [
        ("rejected", "not_found"),
        ("rejected", "parent_not_found"),
        ("rejected", "not_found"),
    ]
    owner_results = await push_as(
        client,
        owner,
        [m("profile", "delete", ward, seconds=30), m("profile", "upsert", ward, profile, 30)],
    )
    assert outcome(owner_results[0]) == ("applied", None)
    assert outcome(owner_results[1]) == ("ignored_stale", "deleted")  # tombstones are terminal
    assert owner_results[1]["current"]["data"] is None
