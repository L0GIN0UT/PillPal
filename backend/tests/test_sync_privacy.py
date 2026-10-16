"""What relatives receive through pull, and every privacy transition (ADR 0006 §3, §4)."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import User, create_managed_profile, link_accounts, register
from tests.sync_helpers import (
    make_event,
    make_medication,
    make_schedule,
    scoped_pull,
    set_privacy,
    sync_all,
)


@dataclass
class Med:
    id: str
    schedule: str
    event: str


@dataclass
class World:
    owner: User
    relative: User
    meds: dict[str, Med]

    @property
    def pid(self) -> str:
        return self.owner.self_profile_id

    async def pull(self, client: AsyncClient, cursor: int = 0, limit: int = 100) -> Any:
        return await scoped_pull(client, self.relative, {self.pid: cursor}, limit=limit)

    async def sync(self, client: AsyncClient) -> Any:
        return await sync_all(client, self.relative, {self.pid: 0})


async def med_with_children(client: AsyncClient, owner: User, profile_id: str, privacy: str) -> Med:
    mid = await make_medication(
        client,
        owner,
        profile_id,
        privacy,
        name=f"SECRET-name-{privacy}",
        notes=f"SECRET-notes-{privacy}",
    )
    return Med(mid, await make_schedule(client, owner, mid), await make_event(client, owner, mid))


async def world(client: AsyncClient, role: str = "viewer") -> World:
    owner, relative = await register(client), await register(client)
    await link_accounts(client, owner, relative, role)
    meds = {
        level: await med_with_children(client, owner, owner.self_profile_id, level)
        for level in ("shared", "anonymous", "hidden")
    }
    return World(owner, relative, meds)


def cursor_of(page: Any, profile_id: str) -> int:
    return int(next(s for s in page["scopes"] if s["profile_id"] == profile_id)["cursor"])


def shapes(page: Any) -> list[tuple[str, str]]:
    return [(c["entity"], c["op"]) for c in page["changes"]]


# --- what each level looks like ---------------------------------------------------------------


@pytest.mark.parametrize("role", ["viewer", "editor"])
async def test_projected_roles_see_shared_full_anonymous_redacted_and_hidden_not_at_all(
    client: AsyncClient, role: str
) -> None:
    w = await world(client, role)
    seen = await w.sync(client)
    in_scope = [c for c in seen.changes if c["scope"] == w.pid]
    wire = json.dumps(in_scope)

    shared = seen.by_id(w.meds["shared"].id)["data"]
    assert shared["name"] == "SECRET-name-shared"  # shared means shared
    assert "redacted" not in shared

    anonymous = seen.by_id(w.meds["anonymous"].id)["data"]
    assert anonymous == {
        "id": w.meds["anonymous"].id,
        "profile_id": w.pid,
        "privacy": "anonymous",
        "tz_mode": "local",
        "fixed_tz": None,
        "redacted": True,
    }
    schedule = seen.by_id(w.meds["anonymous"].schedule)["data"]
    assert schedule["redacted"] is True
    assert schedule["rule"]["times"] == [{"time": "08:00"}, {"time": "20:00"}]
    assert schedule["rule"]["start_date"] == "2026-10-16"
    assert "dose" not in json.dumps(schedule)

    for level in ("anonymous", "hidden"):
        assert f"SECRET-name-{level}" not in wire
        assert f"SECRET-notes-{level}" not in wire
    hidden = w.meds["hidden"]
    assert {hidden.id, hidden.schedule, hidden.event}.isdisjoint({c["id"] for c in in_scope})
    assert w.meds["anonymous"].event in {c["id"] for c in in_scope}  # time and status only


async def test_projected_dose_events_carry_no_note_and_no_device(client: AsyncClient) -> None:
    w = await world(client)
    seen = await w.sync(client)
    for level in ("shared", "anonymous"):
        event = seen.by_id(w.meds[level].event)["data"]
        assert event["type"] == "taken"
        assert "note" not in event
        assert "device_id" not in event
    assert "felt dizzy" not in json.dumps(seen.changes)


async def test_the_profile_is_projected_to_name_kind_and_zone(client: AsyncClient) -> None:
    w = await world(client)
    seen = await w.sync(client)
    data = seen.by_id(w.pid)["data"]
    assert set(data) == {"id", "kind", "display_name", "timezone"}


async def test_a_guardian_sees_hidden_medications_in_full(client: AsyncClient) -> None:
    owner, guardian = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, guardian, "guardian", ward)
    hidden = await med_with_children(client, owner, ward, "hidden")
    seen = await sync_all(client, guardian, {ward: 0})
    assert seen.by_id(hidden.id)["data"]["name"] == "SECRET-name-hidden"
    assert seen.by_id(hidden.event)["data"]["note"] == "felt dizzy"
    assert seen.by_id(hidden.id)["updated_by_device"] is not None


# --- transitions ------------------------------------------------------------------------------


async def test_shared_to_hidden_emits_one_medication_delete_and_skips_the_children(
    client: AsyncClient,
) -> None:
    w = await world(client)
    first = await w.sync(client)
    shared = w.meds["shared"]
    await set_privacy(client, w.owner, shared.id, "hidden")
    page = await w.pull(client, first.cursors[w.pid])
    assert shapes(page) == [("medication", "delete")]
    gone = page["changes"][0]
    assert gone["id"] == shared.id
    assert gone["data"] is None
    assert gone["updated_by_device"] is None
    # Later edits of the hidden medication are invisible.
    await client.patch(f"/v1/medications/{shared.id}", json={"name": "x"}, headers=w.owner.headers)
    after = await w.pull(client, cursor_of(page, w.pid))
    assert after["changes"] == []


async def test_hidden_to_shared_delivers_the_medication_its_schedules_and_its_events(
    client: AsyncClient,
) -> None:
    w = await world(client)
    first = await w.sync(client)
    hidden = w.meds["hidden"]
    await set_privacy(client, w.owner, hidden.id, "shared")
    page = await w.pull(client, first.cursors[w.pid])
    assert shapes(page) == [
        ("medication", "upsert"),
        ("schedule", "upsert"),
        ("dose_event", "upsert"),
    ]
    assert {c["id"] for c in page["changes"]} == {hidden.id, hidden.schedule, hidden.event}
    assert page["changes"][0]["data"]["name"] == "SECRET-name-hidden"


async def test_hidden_to_anonymous_delivers_the_redacted_forms(client: AsyncClient) -> None:
    w = await world(client)
    first = await w.sync(client)
    hidden = w.meds["hidden"]
    await set_privacy(client, w.owner, hidden.id, "anonymous")
    page = await w.pull(client, first.cursors[w.pid])
    assert shapes(page) == [
        ("medication", "upsert"),
        ("schedule", "upsert"),
        ("dose_event", "upsert"),
    ]
    assert page["changes"][0]["data"]["redacted"] is True
    assert "SECRET" not in json.dumps(page["changes"])


async def test_shared_to_anonymous_redacts_medication_and_schedules_not_events(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    w = await world(client)
    first = await w.sync(client)
    shared = w.meds["shared"]
    events_before = await journal_rows(engine, shared.event)
    await set_privacy(client, w.owner, shared.id, "anonymous")
    page = await w.pull(client, first.cursors[w.pid])
    assert shapes(page) == [("medication", "upsert"), ("schedule", "upsert")]
    assert page["changes"][0]["data"]["redacted"] is True
    assert page["changes"][1]["data"]["redacted"] is True
    assert "SECRET-name-shared" not in json.dumps(page["changes"])
    assert await journal_rows(engine, shared.event) == events_before  # not re-journaled


async def test_anonymous_to_shared_restores_the_full_forms_without_replaying_events(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    w = await world(client)
    first = await w.sync(client)
    anonymous = w.meds["anonymous"]
    events_before = await journal_rows(engine, anonymous.event)
    await set_privacy(client, w.owner, anonymous.id, "shared")
    page = await w.pull(client, first.cursors[w.pid])
    assert shapes(page) == [("medication", "upsert"), ("schedule", "upsert")]
    assert page["changes"][0]["data"]["name"] == "SECRET-name-anonymous"
    assert "redacted" not in page["changes"][0]["data"]
    assert await journal_rows(engine, anonymous.event) == events_before


async def journal_rows(engine: AsyncEngine, entity_id: str) -> list[tuple[int, str]]:
    async with engine.connect() as conn:
        rows = await conn.execute(
            text("SELECT seq, op FROM sync_changes WHERE entity_id = :i ORDER BY seq"),
            {"i": entity_id},
        )
        return [(r[0], r[1]) for r in rows]


async def test_the_journal_records_a_privacy_row_and_replays_exactly_what_needs_it(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    w = await world(client)
    shared, hidden = w.meds["shared"], w.meds["hidden"]
    await set_privacy(client, w.owner, shared.id, "anonymous")
    assert [op for _, op in await journal_rows(engine, shared.id)][-1] == "privacy"
    assert [op for _, op in await journal_rows(engine, shared.schedule)] == ["upsert", "upsert"]
    assert len(await journal_rows(engine, shared.event)) == 1
    await set_privacy(client, w.owner, hidden.id, "shared")
    assert len(await journal_rows(engine, hidden.event)) == 2  # hidden -> visible replays them
    await set_privacy(client, w.owner, hidden.id, "hidden")
    assert len(await journal_rows(engine, hidden.event)) == 2  # visible -> hidden does not
    # An update that keeps the level is a plain upsert.
    await client.patch(f"/v1/medications/{shared.id}", json={"name": "n"}, headers=w.owner.headers)
    assert [op for _, op in await journal_rows(engine, shared.id)][-1] == "upsert"


# --- backfills never reveal hidden ids --------------------------------------------------------


async def test_a_backfill_from_zero_emits_no_deletes_for_hidden_medications(
    client: AsyncClient,
) -> None:
    w = await world(client)
    await set_privacy(
        client, w.owner, w.meds["shared"].id, "hidden"
    )  # narrowed before anyone pulled
    seen = await w.sync(client)
    assert seen.of("medication", "delete") == []
    assert w.meds["shared"].id not in {c["id"] for c in seen.changes}


async def test_a_narrowing_from_before_the_grant_never_reveals_ids_even_from_a_later_cursor(
    client: AsyncClient,
) -> None:
    owner, latecomer = await register(client), await register(client)
    mid = await make_medication(client, owner, owner.self_profile_id, name="SECRET-name")
    await set_privacy(client, owner, mid, "hidden")
    await link_accounts(client, owner, latecomer, "viewer")
    # A hostile client skips the backfill rule by sending a non-zero cursor.
    page = await scoped_pull(client, latecomer, {owner.self_profile_id: 1})
    assert [c for c in page["changes"] if c["id"] == mid] == []


async def test_a_narrowing_after_the_grant_reaches_a_client_with_a_cursor(
    client: AsyncClient,
) -> None:
    owner, viewer = await register(client), await register(client)
    await link_accounts(client, owner, viewer, "viewer")
    mid = await make_medication(client, owner, owner.self_profile_id)
    first = await sync_all(client, viewer, {owner.self_profile_id: 0})
    assert mid in first.ids("medication")
    await set_privacy(client, owner, mid, "hidden")
    page = await scoped_pull(
        client, viewer, {owner.self_profile_id: first.cursors[owner.self_profile_id]}
    )
    assert shapes(page) == [("medication", "delete")]


# --- tombstones -------------------------------------------------------------------------------


async def test_tombstones_of_hidden_medications_and_their_children_are_not_sent(
    client: AsyncClient,
) -> None:
    w = await world(client)
    first = await w.sync(client)
    hidden, shared = w.meds["hidden"], w.meds["shared"]
    for med in (hidden, shared):
        resp = await client.delete(f"/v1/medications/{med.id}", headers=w.owner.headers)
        assert resp.status_code == 204
    page = await w.pull(client, first.cursors[w.pid])
    assert {c["id"] for c in page["changes"]} == {shared.id, shared.schedule}
    assert {c["op"] for c in page["changes"]} == {"delete"}
    assert hidden.id not in json.dumps(page["changes"])
    assert hidden.schedule not in json.dumps(page["changes"])


async def test_anonymous_tombstones_are_sent(client: AsyncClient) -> None:
    w = await world(client)
    first = await w.sync(client)
    anonymous = w.meds["anonymous"]
    await client.delete(f"/v1/medications/{anonymous.id}", headers=w.owner.headers)
    page = await w.pull(client, first.cursors[w.pid])
    assert (anonymous.id, "delete") in {(c["id"], c["op"]) for c in page["changes"]}


# --- owners are never projected ---------------------------------------------------------------


async def test_the_owner_receives_everything_unprojected_whatever_the_levels(
    client: AsyncClient,
) -> None:
    w = await world(client)
    seen = await sync_all(client, w.owner)
    for level in ("shared", "anonymous", "hidden"):
        med = seen.by_id(w.meds[level].id)
        assert med["data"]["name"] == f"SECRET-name-{level}"
        assert "redacted" not in med["data"]
        assert seen.by_id(w.meds[level].event)["data"]["note"] == "felt dizzy"


async def test_a_privacy_change_pushed_by_the_owner_is_journaled_like_a_rest_one(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    from datetime import UTC, datetime, timedelta

    from tests.sync_helpers import push_as

    w = await world(client)
    first = await w.sync(client)
    shared = w.meds["shared"]
    stored = (await client.get(f"/v1/medications/{shared.id}", headers=w.owner.headers)).json()
    data = {k: stored[k] for k in ("name", "form", "tz_mode", "fixed_tz", "notes")}
    mutation = {
        "entity": "medication",
        "op": "upsert",
        "id": shared.id,
        "data": {**data, "profile_id": w.pid, "privacy": "hidden"},
        "client_updated_at": (datetime.now(UTC) + timedelta(seconds=30)).isoformat(),
    }
    result = (await push_as(client, w.owner, [mutation]))[0]
    assert (result["status"], result["code"]) == ("applied", None)
    assert [op for _, op in await journal_rows(engine, shared.id)][-1] == "privacy"
    page = await w.pull(client, first.cursors[w.pid])
    assert shapes(page) == [("medication", "delete")]
