"""Sync push/pull: LWW, tombstones, idempotent replay, isolation, ownership."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import User, create_medication, daily_rule, register

T0 = datetime(2026, 10, 1, 8, 0, tzinfo=UTC)


def ts(minutes: int = 0) -> str:
    return (T0 + timedelta(minutes=minutes)).isoformat()


def mut(
    entity: str, op: str, id_: str, data: dict[str, Any] | None = None, minutes: int = 0
) -> dict[str, Any]:
    return {"entity": entity, "op": op, "id": id_, "data": data, "client_updated_at": ts(minutes)}


def med_data(profile_id: str, **overrides: Any) -> dict[str, Any]:
    data: dict[str, Any] = {"profile_id": profile_id, "name": "Metformin", "tz_mode": "local"}
    data.update(overrides)
    return data


async def push(
    client: AsyncClient, user: User, device: str, mutations: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    resp = await client.post(
        "/v1/sync/push", json={"mutations": mutations}, headers=user.device(device)
    )
    assert resp.status_code == 200, resp.text
    results: list[dict[str, Any]] = resp.json()["results"]
    assert [r["id"] for r in results] == [m["id"] for m in mutations]
    return results


async def pull(client: AsyncClient, user: User, cursor: int = 0, limit: int = 100) -> Any:
    resp = await client.get(
        "/v1/sync/pull", params={"cursor": cursor, "limit": limit}, headers=user.headers
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


async def change_count(engine: AsyncEngine) -> int:
    async with engine.connect() as conn:
        return int((await conn.execute(text("SELECT count(*) FROM sync_changes"))).scalar_one())


async def test_push_requires_device_header(client: AsyncClient) -> None:
    user = await register(client)
    resp = await client.post("/v1/sync/push", json={"mutations": []}, headers=user.headers)
    assert resp.status_code == 422
    resp = await client.post(
        "/v1/sync/push", json={"mutations": []}, headers=user.device("bad id!")
    )
    assert resp.status_code == 422


async def test_push_creates_full_graph_and_pull_returns_it(client: AsyncClient) -> None:
    user = await register(client)
    pid, mid, sid, eid = (str(uuid.uuid4()) for _ in range(4))
    results = await push(
        client,
        user,
        "phone-a",
        [
            mut("profile", "upsert", pid, {"display_name": "Grandma", "timezone": "Asia/Omsk"}),
            mut("medication", "upsert", mid, med_data(pid)),
            mut("schedule", "upsert", sid, {"medication_id": mid, "rule": daily_rule()}),
            mut(
                "dose_event",
                "upsert",
                eid,
                {
                    "medication_id": mid,
                    "type": "taken",
                    "at": ts(5),
                    "occurrence_key": f"{sid}/2026-10-01T08:00",
                },
            ),
        ],
    )
    assert [r["status"] for r in results] == ["applied"] * 4
    assert results[1]["version"] == 1

    page = await pull(client, user)
    assert page["has_more"] is False
    by_entity = {c["entity"]: c for c in page["changes"] if c["id"] in {pid, mid, sid, eid}}
    assert set(by_entity) == {"profile", "medication", "schedule", "dose_event"}
    assert by_entity["medication"]["data"]["name"] == "Metformin"
    assert by_entity["schedule"]["data"]["rule"]["kind"] == "daily"
    assert by_entity["dose_event"]["data"]["device_id"] == "phone-a"
    assert by_entity["dose_event"]["data"]["profile_id"] == pid
    assert all(c["op"] == "upsert" for c in page["changes"])
    seqs = [c["seq"] for c in page["changes"]]
    assert seqs == sorted(seqs)
    assert page["next_cursor"] == seqs[-1]
    # Nothing new after the cursor.
    empty = await pull(client, user, cursor=page["next_cursor"])
    assert empty == {"changes": [], "next_cursor": page["next_cursor"], "has_more": False}


async def test_replaying_a_push_is_idempotent(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    mid, eid = str(uuid.uuid4()), str(uuid.uuid4())
    batch = [
        mut("medication", "upsert", mid, med_data(user.self_profile_id)),
        mut("dose_event", "upsert", eid, {"medication_id": mid, "type": "taken", "at": ts()}),
    ]
    first = await push(client, user, "phone-a", batch)
    before = await change_count(engine)
    again = await push(client, user, "phone-a", batch)
    assert first == again
    assert [r["status"] for r in again] == ["applied", "applied"]
    assert await change_count(engine) == before
    async with engine.connect() as conn:
        n = (await conn.execute(text("SELECT count(*) FROM dose_events"))).scalar_one()
    assert n == 1


async def test_two_devices_last_write_wins(client: AsyncClient) -> None:
    user = await register(client)
    mid = str(uuid.uuid4())
    pid = user.self_profile_id
    await push(client, user, "phone", [mut("medication", "upsert", mid, med_data(pid), 0)])

    # Tablet edited later (by client clock) but syncs first; phone's older edit arrives after.
    tablet = await push(
        client, user, "tablet", [mut("medication", "upsert", mid, med_data(pid, name="B"), 20)]
    )
    phone = await push(
        client, user, "phone", [mut("medication", "upsert", mid, med_data(pid, name="A"), 10)]
    )
    assert tablet[0]["status"] == "applied"
    assert tablet[0]["version"] == 2
    assert phone[0]["status"] == "ignored_stale"
    assert phone[0]["version"] == 2
    current = await client.get(f"/v1/medications/{mid}", headers=user.headers)
    assert current.json()["name"] == "B"

    # Equal timestamps: the larger device id wins, regardless of arrival order.
    z = await push(
        client, user, "zz-device", [mut("medication", "upsert", mid, med_data(pid, name="Z"), 30)]
    )
    a = await push(
        client, user, "aa-device", [mut("medication", "upsert", mid, med_data(pid, name="Y"), 30)]
    )
    assert z[0]["status"] == "applied"
    assert a[0]["status"] == "ignored_stale"
    assert (await client.get(f"/v1/medications/{mid}", headers=user.headers)).json()["name"] == "Z"


async def test_tombstones_are_terminal_and_pulled(client: AsyncClient) -> None:
    user = await register(client)
    pid = user.self_profile_id
    mid, sid = str(uuid.uuid4()), str(uuid.uuid4())
    await push(
        client,
        user,
        "phone",
        [
            mut("medication", "upsert", mid, med_data(pid), 0),
            mut("schedule", "upsert", sid, {"medication_id": mid, "rule": daily_rule()}, 0),
        ],
    )
    cursor = (await pull(client, user))["next_cursor"]

    # Deletes are final: even an "older" delete wins over the stored write.
    deleted = await push(client, user, "tablet", [mut("medication", "delete", mid, None, -5)])
    assert deleted[0]["status"] == "applied"
    # A newer upsert does not resurrect a tombstone.
    zombie = await push(
        client, user, "phone", [mut("medication", "upsert", mid, med_data(pid, name="Z"), 60)]
    )
    assert zombie[0] == {**zombie[0], "status": "ignored_stale", "code": "deleted"}
    # Deleting again / deleting an unknown id is a harmless no-op.
    again = await push(
        client,
        user,
        "phone",
        [
            mut("medication", "delete", mid, None, 70),
            mut("schedule", "delete", str(uuid.uuid4()), None, 70),
        ],
    )
    assert [r["status"] for r in again] == ["applied", "applied"]

    page = await pull(client, user, cursor=cursor)
    ops = {(c["entity"], c["id"]): (c["op"], c["data"]) for c in page["changes"]}
    assert ops[("medication", mid)] == ("delete", None)
    assert ops[("schedule", sid)] == ("delete", None)  # cascaded tombstone
    assert (await client.get(f"/v1/medications/{mid}", headers=user.headers)).status_code == 404


async def test_one_bad_mutation_does_not_fail_the_batch(client: AsyncClient) -> None:
    user = await register(client)
    pid = user.self_profile_id
    good1, good2, existing = (str(uuid.uuid4()) for _ in range(3))
    await push(client, user, "phone", [mut("medication", "upsert", existing, med_data(pid))])
    other_profile = str(uuid.uuid4())
    results = await push(
        client,
        user,
        "phone",
        [
            mut("medication", "upsert", good1, med_data(pid)),
            mut("medication", "upsert", str(uuid.uuid4()), {"name": "no profile"}),
            mut("schedule", "upsert", str(uuid.uuid4()), {"medication_id": good1, "rule": {}}),
            mut("medication", "upsert", str(uuid.uuid4()), med_data(str(uuid.uuid4()))),
            mut("medication", "upsert", existing, med_data(other_profile), 10),
            mut("dose_event", "delete", str(uuid.uuid4()), None),
            mut(
                "profile",
                "upsert",
                str(uuid.uuid4()),
                {"display_name": "Me", "timezone": "UTC", "kind": "self"},
            ),
            mut("profile", "delete", pid, None, 10),
            {
                **mut("medication", "upsert", str(uuid.uuid4()), med_data(pid)),
                "client_updated_at": (datetime.now(UTC) + timedelta(minutes=30)).isoformat(),
            },
            mut("medication", "upsert", good2, med_data(pid)),
        ],
    )
    summary = [(r["status"], r["code"]) for r in results]
    assert summary == [
        ("applied", None),
        ("rejected", "validation_error"),
        ("rejected", "validation_error"),
        ("rejected", "parent_not_found"),
        ("rejected", "immutable_field"),
        ("rejected", "append_only"),
        ("rejected", "invalid_kind"),
        ("rejected", "self_profile_protected"),
        ("rejected", "clock_skew"),
        ("applied", None),
    ]
    for mid in (good1, good2):
        assert (await client.get(f"/v1/medications/{mid}", headers=user.headers)).status_code == 200


async def test_dose_event_conflicts_and_profile_updates_via_sync(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    eid = str(uuid.uuid4())
    taken = {"medication_id": med["id"], "type": "taken", "at": ts()}
    results = await push(
        client,
        user,
        "phone",
        [
            mut("dose_event", "upsert", eid, taken),
            mut("dose_event", "upsert", eid, {**taken, "type": "skipped"}),
            mut(
                "dose_event",
                "upsert",
                str(uuid.uuid4()),
                {**taken, "medication_id": str(uuid.uuid4())},
            ),
            # The self profile was created at registration (now): edit it later.
            {
                **mut(
                    "profile",
                    "upsert",
                    user.self_profile_id,
                    {"kind": "self", "display_name": "Ivan", "timezone": "Europe/Samara"},
                ),
                "client_updated_at": (datetime.now(UTC) + timedelta(seconds=1)).isoformat(),
            },
            {
                **mut(
                    "profile",
                    "upsert",
                    user.self_profile_id,
                    {"kind": "managed", "display_name": "X", "timezone": "UTC"},
                ),
                "client_updated_at": (datetime.now(UTC) + timedelta(seconds=2)).isoformat(),
            },
        ],
    )
    assert [(r["status"], r["code"]) for r in results] == [
        ("applied", None),
        ("rejected", "idempotency_conflict"),
        ("rejected", "parent_not_found"),
        ("applied", None),
        ("rejected", "immutable_field"),
    ]
    me = await client.get(f"/v1/profiles/{user.self_profile_id}", headers=user.headers)
    assert me.json()["display_name"] == "Ivan"


async def test_schedule_and_profile_lww_via_sync(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
    sched = {"medication_id": med["id"], "rule": daily_rule()}
    prof = {"display_name": "Kid", "timezone": "UTC"}
    await push(
        client,
        user,
        "a",
        [mut("schedule", "upsert", sid, sched, 0), mut("profile", "upsert", pid, prof, 0)],
    )
    results = await push(
        client,
        user,
        "a",
        [
            mut("schedule", "upsert", sid, {**sched, "rule": daily_rule(("10:00",))}, 5),
            mut("schedule", "upsert", sid, {**sched, "rule": daily_rule(("11:00",))}, 1),
            mut(
                "schedule",
                "upsert",
                sid,
                {"medication_id": str(uuid.uuid4()), "rule": daily_rule()},
                9,
            ),
            mut("profile", "upsert", pid, {**prof, "display_name": "Kiddo"}, 5),
            mut("profile", "delete", pid, None, 1),
            mut("schedule", "delete", sid, None, 6),
            mut("profile", "delete", pid, None, 7),
        ],
    )
    assert [(r["status"], r["code"]) for r in results] == [
        ("applied", None),
        ("ignored_stale", None),
        ("rejected", "immutable_field"),
        ("applied", None),
        ("applied", None),  # deletes win regardless of timestamps
        ("applied", None),
        ("applied", None),  # already a tombstone: idempotent
    ]
    assert (await client.get(f"/v1/profiles/{pid}", headers=user.headers)).status_code == 404


async def test_rest_writes_are_journaled_for_pull(client: AsyncClient) -> None:
    user = await register(client)
    first = await pull(client, user)
    # Registration journals the self profile.
    assert [(c["entity"], c["id"]) for c in first["changes"]] == [("profile", user.self_profile_id)]
    med = await create_medication(client, user)
    await client.patch(f"/v1/medications/{med['id']}", json={"name": "X"}, headers=user.headers)
    page = await pull(client, user, cursor=first["next_cursor"])
    # Two journal rows for one entity collapse into its latest state.
    assert len(page["changes"]) == 1
    assert page["changes"][0]["data"]["name"] == "X"
    assert page["changes"][0]["data"]["version"] == 2


async def test_sync_is_owner_scoped(client: AsyncClient) -> None:
    alice = await register(client)
    bob = await register(client)
    med = await create_medication(client, alice)
    results = await push(
        client,
        bob,
        "bob-phone",
        [
            mut("medication", "upsert", med["id"], med_data(bob.self_profile_id, name="pwn"), 99),
            mut("medication", "delete", med["id"], None, 99),
            mut("medication", "upsert", str(uuid.uuid4()), med_data(alice.self_profile_id)),
            mut(
                "schedule",
                "upsert",
                str(uuid.uuid4()),
                {"medication_id": med["id"], "rule": daily_rule()},
            ),
            mut("profile", "delete", alice.self_profile_id, None, 99),
        ],
    )
    assert [(r["status"], r["code"]) for r in results] == [
        ("rejected", "already_exists"),
        ("applied", None),  # unknown to Bob: a no-op
        ("rejected", "parent_not_found"),
        ("rejected", "parent_not_found"),
        ("applied", None),
    ]
    alice_med = await client.get(f"/v1/medications/{med['id']}", headers=alice.headers)
    assert alice_med.status_code == 200
    assert alice_med.json()["name"] == "Aspirin"
    bob_pull = await pull(client, bob)
    assert {c["id"] for c in bob_pull["changes"]} == {bob.self_profile_id}
