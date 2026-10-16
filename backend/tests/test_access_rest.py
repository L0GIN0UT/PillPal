"""REST is for full-access roles: owner and guardian 200, editor and viewer 404 (ADR 0006 §6)."""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from httpx import AsyncClient

from tests.helpers import (
    User,
    create_managed_profile,
    daily_rule,
    link_accounts,
    register,
)
from tests.sync_helpers import make_event, make_medication, make_schedule, sync_all


async def setup(client: AsyncClient) -> dict[str, Any]:
    owner, guardian, editor, viewer = [await register(client) for _ in range(4)]
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, guardian, "guardian", ward)
    await link_accounts(client, owner, editor, "editor", ward)
    await link_accounts(client, owner, viewer, "viewer", ward)
    mid = await make_medication(client, owner, ward)
    return {
        "owner": owner,
        "guardian": guardian,
        "editor": editor,
        "viewer": viewer,
        "ward": ward,
        "med": mid,
        "sched": await make_schedule(client, owner, mid),
        "event": await make_event(client, owner, mid),
    }


async def test_a_guardian_reads_the_managed_profile_over_rest(client: AsyncClient) -> None:
    w = await setup(client)
    g: User = w["guardian"]
    assert (await client.get(f"/v1/profiles/{w['ward']}", headers=g.headers)).status_code == 200
    meds = await client.get(f"/v1/profiles/{w['ward']}/medications", headers=g.headers)
    assert [x["id"] for x in meds.json()["items"]] == [w["med"]]
    assert (await client.get(f"/v1/medications/{w['med']}", headers=g.headers)).status_code == 200
    scheds = await client.get(f"/v1/medications/{w['med']}/schedules", headers=g.headers)
    assert [x["id"] for x in scheds.json()["items"]] == [w["sched"]]
    assert (await client.get(f"/v1/schedules/{w['sched']}", headers=g.headers)).status_code == 200
    events = await client.get(
        "/v1/dose-events", params={"profile_id": w["ward"]}, headers=g.headers
    )
    assert [x["id"] for x in events.json()["items"]] == [w["event"]]
    assert (await client.get(f"/v1/dose-events/{w['event']}", headers=g.headers)).status_code == 200
    listed = await client.get("/v1/profiles", headers=g.headers)
    assert w["ward"] in {p["id"] for p in listed.json()["items"]}


async def test_a_guardian_writes_the_managed_profile_over_rest(client: AsyncClient) -> None:
    w = await setup(client)
    g: User = w["guardian"]
    patched = await client.patch(
        f"/v1/profiles/{w['ward']}", json={"display_name": "By guardian"}, headers=g.headers
    )
    assert patched.status_code == 200
    new_med = str(uuid.uuid4())
    created = await client.post(
        f"/v1/profiles/{w['ward']}/medications",
        json={"id": new_med, "name": "Guard med", "privacy": "hidden"},
        headers=g.headers,
    )
    assert created.status_code == 201
    new_sched = str(uuid.uuid4())
    sched = await client.post(
        f"/v1/medications/{new_med}/schedules",
        json={"id": new_sched, "rule": daily_rule()},
        headers=g.headers,
    )
    assert sched.status_code == 201
    event = await client.post(
        "/v1/dose-events",
        json={
            "id": str(uuid.uuid4()),
            "medication_id": new_med,
            "type": "taken",
            "at": "2026-10-16T08:00:00Z",
        },
        headers=g.device("guardian-phone"),
    )
    assert event.status_code == 201
    assert (
        await client.patch(
            f"/v1/medications/{new_med}", json={"name": "Renamed"}, headers=g.headers
        )
    ).status_code == 200
    assert (
        await client.patch(
            f"/v1/schedules/{new_sched}", json={"rule": daily_rule(("07:00",))}, headers=g.headers
        )
    ).status_code == 200
    assert (await client.delete(f"/v1/schedules/{new_sched}", headers=g.headers)).status_code == 204
    assert (await client.delete(f"/v1/medications/{new_med}", headers=g.headers)).status_code == 204


async def test_the_guardians_rest_writes_reach_the_owners_pull(client: AsyncClient) -> None:
    w = await setup(client)
    g: User = w["guardian"]
    new_med = str(uuid.uuid4())
    await client.post(
        f"/v1/profiles/{w['ward']}/medications",
        json={"id": new_med, "name": "Guard med"},
        headers=g.headers,
    )
    seen = await sync_all(client, w["owner"], {w["ward"]: 0})
    assert new_med in seen.ids("medication")


@pytest.mark.parametrize("who", ["editor", "viewer"])
async def test_editors_and_viewers_look_like_strangers_to_rest(
    client: AsyncClient, who: str
) -> None:
    w = await setup(client)
    u: User = w[who]
    ward, mid, sid, eid = w["ward"], w["med"], w["sched"], w["event"]
    new = str(uuid.uuid4())
    calls = [
        ("GET", f"/v1/profiles/{ward}", None),
        ("PATCH", f"/v1/profiles/{ward}", {"display_name": "X"}),
        ("DELETE", f"/v1/profiles/{ward}", None),
        ("GET", f"/v1/profiles/{ward}/medications", None),
        ("POST", f"/v1/profiles/{ward}/medications", {"id": new, "name": "X"}),
        ("GET", f"/v1/medications/{mid}", None),
        ("PATCH", f"/v1/medications/{mid}", {"name": "X"}),
        ("DELETE", f"/v1/medications/{mid}", None),
        ("GET", f"/v1/medications/{mid}/schedules", None),
        ("POST", f"/v1/medications/{mid}/schedules", {"id": new, "rule": daily_rule()}),
        ("GET", f"/v1/schedules/{sid}", None),
        ("PATCH", f"/v1/schedules/{sid}", {"rule": daily_rule()}),
        ("DELETE", f"/v1/schedules/{sid}", None),
        (
            "POST",
            "/v1/dose-events",
            {"id": new, "medication_id": mid, "type": "taken", "at": "2026-10-16T08:00:00Z"},
        ),
        ("GET", f"/v1/dose-events/{eid}", None),
    ]
    for method, url, body in calls:
        resp = await client.request(method, url, json=body, headers=u.headers)
        assert resp.status_code == 404, (method, url, resp.status_code)
    listed = await client.get("/v1/dose-events", params={"profile_id": ward}, headers=u.headers)
    assert listed.json()["items"] == []
    own = await client.get("/v1/profiles", headers=u.headers)
    assert ward not in {p["id"] for p in own.json()["items"]}
    # And nothing changed.
    assert (await client.get(f"/v1/medications/{mid}", headers=w["owner"].headers)).json()[
        "name"
    ] == "Synthetic Tablet"


async def test_a_guardian_cannot_delete_a_non_archived_managed_profile(client: AsyncClient) -> None:
    w = await setup(client)
    resp = await client.delete(f"/v1/profiles/{w['ward']}", headers=w["guardian"].headers)
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "forbidden"
    assert (
        await client.get(f"/v1/profiles/{w['ward']}", headers=w["owner"].headers)
    ).status_code == 200
    assert (
        await client.delete(f"/v1/profiles/{w['ward']}", headers=w["owner"].headers)
    ).status_code == 204
    # The guardian's scope went with the profile: 404 now, and still no way to delete it.
    gone = await client.delete(f"/v1/profiles/{w['ward']}", headers=w["guardian"].headers)
    assert gone.status_code == 404
    # The owner can repeat the delete, but nothing else touches a tombstone.
    again = await client.delete(f"/v1/profiles/{w['ward']}", headers=w["owner"].headers)
    assert again.status_code == 204
    renamed = await client.patch(
        f"/v1/profiles/{w['ward']}", json={"display_name": "X"}, headers=w["owner"].headers
    )
    assert renamed.status_code == 404


async def test_rest_write_endpoints_still_require_authentication_and_valid_bodies(
    client: AsyncClient,
) -> None:
    w = await setup(client)
    g: User = w["guardian"]
    unauthenticated = await client.patch(f"/v1/medications/{w['med']}", json={"name": "X"})
    assert unauthenticated.status_code == 401
    invalid = await client.patch(
        f"/v1/medications/{w['med']}", json={"name": ""}, headers=g.headers
    )
    assert invalid.status_code == 422
    assert (
        await client.patch(f"/v1/medications/{uuid.uuid4()}", json={"name": "X"}, headers=g.headers)
    ).status_code == 404
