"""Sync convergence: conflict keys, deletes win, parents, page order, skew."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from httpx import AsyncClient

from tests.helpers import create_medication, daily_rule, register
from tests.test_sync import med_data, mut, pull, push, ts


def dt(value: str) -> datetime:
    return datetime.fromisoformat(value)


def by_id(page: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {c["id"]: c for c in page["changes"]}


# --- 2. pulled changes carry the conflict key -------------------------------------


async def test_pulled_changes_carry_conflict_key(client: AsyncClient) -> None:
    user = await register(client)
    mid, sid, eid = (str(uuid.uuid4()) for _ in range(3))
    await push(
        client,
        user,
        "phone",
        [
            mut("medication", "upsert", mid, med_data(user.self_profile_id), 0),
            mut("schedule", "upsert", sid, {"medication_id": mid, "rule": daily_rule()}, 1),
            mut("dose_event", "upsert", eid, {"medication_id": mid, "type": "taken", "at": ts()}),
        ],
    )
    await push(client, user, "tablet", [mut("medication", "delete", mid, None, 2)])
    changes = by_id(await pull(client, user))

    med = changes[mid]
    assert (med["op"], med["data"]) == ("delete", None)
    assert dt(med["client_updated_at"]) == dt(ts(2))
    assert med["updated_by_device"] == "tablet"
    assert med["deleted_at"] is not None

    sched = changes[sid]
    assert (sched["op"], sched["data"]) == ("delete", None)
    assert dt(sched["client_updated_at"]) == dt(ts(2))
    assert sched["updated_by_device"] == "tablet"
    assert sched["deleted_at"] is not None

    me = changes[user.self_profile_id]
    assert me["op"] == "upsert"
    assert me["client_updated_at"] is not None
    assert me["updated_by_device"] == ""
    assert me["deleted_at"] is None

    event = changes[eid]
    assert event["op"] == "upsert"
    assert [event[k] for k in ("client_updated_at", "updated_by_device", "deleted_at")] == [
        None
    ] * 3


# --- 3. ignored_stale carries the server state; key conflicts ------------------------


async def test_ignored_stale_returns_current_server_state(client: AsyncClient) -> None:
    user = await register(client)
    pid = user.self_profile_id
    mid = str(uuid.uuid4())
    await push(
        client, user, "phone", [mut("medication", "upsert", mid, med_data(pid, name="A"), 20)]
    )
    stale = (
        await push(
            client, user, "tablet", [mut("medication", "upsert", mid, med_data(pid, name="B"), 10)]
        )
    )[0]
    assert stale["status"] == "ignored_stale"
    current = stale["current"]
    assert current["op"] == "upsert"
    assert current["data"]["name"] == "A"
    assert current["data"]["version"] == 1
    assert dt(current["client_updated_at"]) == dt(ts(20))
    assert current["updated_by_device"] == "phone"
    assert current["deleted_at"] is None

    await push(client, user, "phone", [mut("medication", "delete", mid, None, 30)])
    zombie = (
        await push(
            client, user, "tablet", [mut("medication", "upsert", mid, med_data(pid, name="C"), 40)]
        )
    )[0]
    assert (zombie["status"], zombie["code"]) == ("ignored_stale", "deleted")
    assert zombie["current"]["op"] == "delete"
    assert zombie["current"]["data"] is None
    assert zombie["current"]["deleted_at"] is not None

    applied = (await push(client, user, "phone", [mut("medication", "delete", mid, None, 50)]))[0]
    assert applied["status"] == "applied"
    assert applied.get("current") is None


async def test_equal_key_with_different_payload_is_key_conflict(client: AsyncClient) -> None:
    user = await register(client)
    pid = user.self_profile_id
    med = await create_medication(client, user)
    mid, sid, prof = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
    sched = {"medication_id": med["id"], "rule": daily_rule()}
    profile = {"display_name": "Kid", "timezone": "UTC"}
    first = [
        mut("medication", "upsert", mid, med_data(pid, name="A"), 5),
        mut("schedule", "upsert", sid, sched, 5),
        mut("profile", "upsert", prof, profile, 5),
    ]
    await push(client, user, "phone", first)
    # Identical replay: idempotent success, nothing changes.
    replay = await push(client, user, "phone", first)
    assert [(r["status"], r["version"]) for r in replay] == [("applied", 1)] * 3

    conflicting = await push(
        client,
        user,
        "phone",
        [
            mut("medication", "upsert", mid, med_data(pid, name="B"), 5),
            mut("schedule", "upsert", sid, {**sched, "rule": daily_rule(("09:00",))}, 5),
            mut("profile", "upsert", prof, {**profile, "display_name": "Other"}, 5),
        ],
    )
    assert [(r["status"], r["code"]) for r in conflicting] == [("rejected", "key_conflict")] * 3
    assert conflicting[0]["current"]["data"]["name"] == "A"
    got = await client.get(f"/v1/medications/{mid}", headers=user.headers)
    assert got.json()["name"] == "A"


# --- 4. deletes always win ------------------------------------------------------------


@pytest.mark.parametrize("delete_first", [True, False])
async def test_edit_vs_delete_converges_to_deleted_in_any_order(
    client: AsyncClient, delete_first: bool
) -> None:
    user = await register(client)
    pid = user.self_profile_id
    mid = str(uuid.uuid4())
    await push(client, user, "phone", [mut("medication", "upsert", mid, med_data(pid), 0)])
    edit = ("tablet", mut("medication", "upsert", mid, med_data(pid, name="Edited"), 50))
    delete = ("phone", mut("medication", "delete", mid, None, 10))
    order = [delete, edit] if delete_first else [edit, delete]
    statuses = [(await push(client, user, dev, [m]))[0]["status"] for dev, m in order]
    assert statuses == (["applied", "ignored_stale"] if delete_first else ["applied", "applied"])
    assert (await client.get(f"/v1/medications/{mid}", headers=user.headers)).status_code == 404
    assert by_id(await pull(client, user))[mid]["op"] == "delete"


# --- 5. children cannot be created under a deleted parent -----------------------------


async def test_child_create_under_deleted_parent_is_rejected(client: AsyncClient) -> None:
    user = await register(client)
    pid, mid, mid2, sid, sid2 = (str(uuid.uuid4()) for _ in range(5))
    profile = {"display_name": "Grandma", "timezone": "UTC"}
    results = await push(
        client,
        user,
        "phone",
        [
            mut("profile", "upsert", pid, profile),
            mut("medication", "upsert", mid, med_data(pid)),
            mut("profile", "delete", pid, None, 1),
            # Same batch, after the cascade: the medication is a tombstone now.
            mut("schedule", "upsert", sid, {"medication_id": mid, "rule": daily_rule()}, 2),
            mut("medication", "upsert", mid2, med_data(pid), 2),
        ],
    )
    assert [(r["status"], r["code"]) for r in results] == [
        ("applied", None),
        ("applied", None),
        ("applied", None),
        ("rejected", "parent_deleted"),
        ("rejected", "parent_deleted"),
    ]
    later = await push(
        client,
        user,
        "tablet",
        [mut("schedule", "upsert", sid2, {"medication_id": mid, "rule": daily_rule()}, 3)],
    )
    assert (later[0]["status"], later[0]["code"]) == ("rejected", "parent_deleted")

    # The parent was already loaded earlier in the batch, then tombstoned by a
    # cascade: the parent check must see the tombstone, not a stale instance.
    pid3, mid3, sid3 = (str(uuid.uuid4()) for _ in range(3))
    await push(
        client,
        user,
        "phone",
        [
            mut("profile", "upsert", pid3, profile),
            mut("medication", "upsert", mid3, med_data(pid3)),
        ],
    )
    results = await push(
        client,
        user,
        "phone",
        [
            mut("medication", "upsert", mid3, med_data(pid3, name="Renamed"), 4),
            mut("profile", "delete", pid3, None, 5),
            mut("schedule", "upsert", sid3, {"medication_id": mid3, "rule": daily_rule()}, 6),
            mut("medication", "upsert", mid3, med_data(pid3, name="Again"), 7),
        ],
    )
    assert [(r["status"], r["code"]) for r in results] == [
        ("applied", None),
        ("applied", None),
        ("rejected", "parent_deleted"),
        ("ignored_stale", "deleted"),
    ]

    # REST: a deleted parent is invisible, so creating under it is a 404.
    resp = await client.post(
        f"/v1/medications/{mid}/schedules",
        json={"id": str(uuid.uuid4()), "rule": daily_rule()},
        headers=user.headers,
    )
    assert resp.status_code == 404
    resp = await client.post(
        f"/v1/profiles/{pid}/medications",
        json={"id": str(uuid.uuid4()), "name": "X"},
        headers=user.headers,
    )
    assert resp.status_code == 404


# --- 6. parents before children within a page -----------------------------------------


async def test_pull_page_orders_entities_by_first_appearance(client: AsyncClient) -> None:
    user = await register(client)
    cursor = (await pull(client, user))["next_cursor"]
    pid, mid = str(uuid.uuid4()), str(uuid.uuid4())
    profile = {"display_name": "Kid", "timezone": "UTC"}
    await push(
        client,
        user,
        "phone",
        [
            mut("profile", "upsert", pid, profile, 0),
            mut("medication", "upsert", mid, med_data(pid)),
        ],
    )
    await push(
        client, user, "phone", [mut("profile", "upsert", pid, {**profile, "display_name": "K2"}, 5)]
    )
    page = await pull(client, user, cursor=cursor)
    assert [c["id"] for c in page["changes"]] == [pid, mid]
    assert page["changes"][0]["data"]["display_name"] == "K2"  # current state
    assert page["changes"][0]["data"]["version"] == 2


# --- 7. server-controlled fields in pushed data are ignored -------------------------------


async def test_server_controlled_fields_in_push_data_are_ignored(client: AsyncClient) -> None:
    user = await register(client)
    pid, mid, sid, eid = (str(uuid.uuid4()) for _ in range(4))
    server_fields = {
        "id": str(uuid.uuid4()),
        "version": 99,
        "created_at": "2020-01-01T00:00:00Z",
        "updated_at": "2020-01-01T00:00:00Z",
        "client_updated_at": "2020-01-01T00:00:00Z",
        "updated_by_device": "evil",
        "deleted_at": "2020-01-01T00:00:00Z",
        "owner_user_id": str(uuid.uuid4()),
    }
    results = await push(
        client,
        user,
        "phone",
        [
            mut(
                "profile", "upsert", pid, {"display_name": "P", "timezone": "UTC", **server_fields}
            ),
            mut("medication", "upsert", mid, {**med_data(pid), **server_fields}),
            mut(
                "schedule",
                "upsert",
                sid,
                {"medication_id": mid, "rule": daily_rule(), **server_fields},
            ),
            mut(
                "dose_event",
                "upsert",
                eid,
                {
                    "medication_id": mid,
                    "type": "taken",
                    "at": ts(),
                    "id": str(uuid.uuid4()),
                    "profile_id": str(uuid.uuid4()),
                    "recorded_at": "2020-01-01T00:00:00Z",
                    "device_id": "evil",
                },
            ),
            mut("medication", "upsert", str(uuid.uuid4()), {**med_data(pid), "surprise": 1}),
        ],
    )
    assert [(r["status"], r["code"]) for r in results] == [
        ("applied", None),
        ("applied", None),
        ("applied", None),
        ("applied", None),
        ("rejected", "validation_error"),
    ]
    med = (await client.get(f"/v1/medications/{mid}", headers=user.headers)).json()
    assert med["version"] == 1
    assert med["id"] == mid
    event = (await client.get(f"/v1/dose-events/{eid}", headers=user.headers)).json()
    assert event["profile_id"] == pid
    assert event["device_id"] == "phone"


# --- 8. cascades never move a child's key backwards --------------------------------------


async def test_cascaded_delete_keeps_child_conflict_key_monotonic(client: AsyncClient) -> None:
    user = await register(client)
    pid = user.self_profile_id
    mid, sid = str(uuid.uuid4()), str(uuid.uuid4())
    sched = {"medication_id": mid, "rule": daily_rule()}
    await push(
        client,
        user,
        "phone",
        [mut("medication", "upsert", mid, med_data(pid), 0), mut("schedule", "upsert", sid, sched)],
    )
    await push(
        client,
        user,
        "tablet",
        [mut("schedule", "upsert", sid, {**sched, "rule": daily_rule(("09:00",))}, 60)],
    )
    deleted = await push(client, user, "phone", [mut("medication", "delete", mid, None, 10)])
    assert deleted[0]["status"] == "applied"
    changes = by_id(await pull(client, user))
    assert changes[sid]["op"] == "delete"
    assert dt(changes[sid]["client_updated_at"]) == dt(ts(60))
    assert changes[sid]["updated_by_device"] == "tablet"
    assert dt(changes[mid]["client_updated_at"]) == dt(ts(10))
    assert changes[mid]["updated_by_device"] == "phone"


# --- 9. future clock skew is bounded to 10 minutes ---------------------------------------


async def test_future_clock_skew_is_limited_to_ten_minutes(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    soon = datetime.now(UTC) + timedelta(minutes=5)
    late = datetime.now(UTC) + timedelta(minutes=15)

    def upsert(at: datetime) -> dict[str, Any]:
        m = mut("medication", "upsert", str(uuid.uuid4()), med_data(user.self_profile_id))
        return {**m, "client_updated_at": at.isoformat()}

    def event(at: datetime) -> dict[str, Any]:
        return mut(
            "dose_event",
            "upsert",
            str(uuid.uuid4()),
            {"medication_id": med["id"], "type": "taken", "at": at.isoformat()},
        )

    results = await push(client, user, "d", [upsert(soon), upsert(late), event(soon), event(late)])
    assert [(r["status"], r["code"]) for r in results] == [
        ("applied", None),
        ("rejected", "clock_skew"),
        ("applied", None),
        ("rejected", "validation_error"),
    ]
    for at, expected in ((soon, 201), (late, 422)):
        resp = await client.post(
            "/v1/dose-events",
            json={
                "id": str(uuid.uuid4()),
                "medication_id": med["id"],
                "type": "taken",
                "at": at.isoformat(),
            },
            headers=user.headers,
        )
        assert resp.status_code == expected, resp.text
