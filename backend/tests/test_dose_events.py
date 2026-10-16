"""Dose events: append-only, idempotent by client id, undo semantics."""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import User, create_medication, create_schedule, daily_rule, register


def event(medication_id: str, **overrides: Any) -> dict[str, Any]:
    data: dict[str, Any] = {
        "id": str(uuid.uuid4()),
        "medication_id": medication_id,
        "type": "taken",
        "at": "2026-10-16T08:03:00+04:00",
    }
    data.update(overrides)
    return data


async def post_event(client: AsyncClient, user: User, body: dict[str, Any]) -> Any:
    return await client.post(
        "/v1/dose-events", json=body, headers={**user.headers, "X-Device-ID": "phone-1"}
    )


async def test_record_and_replay_dose_event(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    sched = await create_schedule(client, user, med["id"])
    body = event(med["id"], occurrence_key=f"{sched['id']}/2026-10-16T08:00", note="ok")

    first = await post_event(client, user, body)
    assert first.status_code == 201, first.text
    stored = first.json()
    assert stored["profile_id"] == user.self_profile_id
    assert stored["device_id"] == "phone-1"
    assert stored["at"].startswith("2026-10-16T04:03:00")

    # Same payload (even with an equivalent instant in another offset) -> 200.
    replay = await post_event(client, user, {**body, "at": "2026-10-16T04:03:00Z"})
    assert replay.status_code == 200
    assert replay.json() == stored

    conflict = await post_event(client, user, {**body, "type": "skipped"})
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "idempotency_conflict"

    got = await client.get(f"/v1/dose-events/{stored['id']}", headers=user.headers)
    assert got.json() == stored


async def test_undo_requires_valid_target(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    other_med = await create_medication(client, user)
    taken = (await post_event(client, user, event(med["id"]))).json()

    no_target = await post_event(client, user, event(med["id"], type="undo"))
    assert no_target.status_code == 422
    target_on_taken = await post_event(client, user, event(med["id"], target_event_id=taken["id"]))
    assert target_on_taken.status_code == 422

    wrong_med = await post_event(
        client, user, event(other_med["id"], type="undo", target_event_id=taken["id"])
    )
    assert wrong_med.status_code == 422
    assert wrong_med.json()["error"]["code"] == "invalid_undo_target"
    missing = await post_event(
        client, user, event(med["id"], type="undo", target_event_id=str(uuid.uuid4()))
    )
    assert missing.status_code == 422

    undo = await post_event(
        client, user, event(med["id"], type="undo", target_event_id=taken["id"])
    )
    assert undo.status_code == 201
    undo_of_undo = await post_event(
        client, user, event(med["id"], type="undo", target_event_id=undo.json()["id"])
    )
    assert undo_of_undo.status_code == 422


@pytest.mark.parametrize(
    "overrides",
    [
        {"type": "eaten"},
        {"at": "2026-10-16T08:00:00"},  # naive timestamp
        {"at": "2099-01-01T00:00:00Z"},  # far future
        {"occurrence_key": "garbage"},
        {"occurrence_key": f"{uuid.uuid4()}/2026-02-30T08:00"},
        {"occurrence_key": f"{uuid.uuid4()}/2026-10-16T25:00"},
        # Non-canonical schedule ids are rejected, not silently normalized.
        {"occurrence_key": f"{str(uuid.uuid4()).upper()}/2026-10-16T08:00"},
        {"occurrence_key": f"{uuid.uuid4().hex}/2026-10-16T08:00"},
        {"occurrence_key": f"{{{uuid.uuid4()}}}/2026-10-16T08:00"},
        {"occurrence_key": f"{uuid.uuid4()}/2026-10-16T8:00"},
        {"occurrence_key": f"{uuid.uuid4()}/2026-10-16T08:00:00"},
        {"occurrence_key": f"{uuid.uuid4()}/2026-1-16T08:00"},
        {"note": "x" * 1001},
        {"profile_id": str(uuid.uuid4())},
    ],
)
async def test_dose_event_validation(client: AsyncClient, overrides: dict[str, Any]) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    resp = await post_event(client, user, event(med["id"], **overrides))
    assert resp.status_code == 422, resp.text


async def test_occurrence_key_must_match_medication_schedule(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    other = await create_medication(client, user)
    other_sched = await create_schedule(client, user, other["id"])
    resp = await post_event(
        client, user, event(med["id"], occurrence_key=f"{other_sched['id']}/2026-10-16T08:00")
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "invalid_occurrence_key"
    # A schedule the server has not seen yet is accepted (offline ordering).
    resp = await post_event(
        client, user, event(med["id"], occurrence_key=f"{uuid.uuid4()}/2026-10-16T08:00")
    )
    assert resp.status_code == 201


async def test_events_for_deleted_medication_are_kept(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    await client.delete(f"/v1/medications/{med['id']}", headers=user.headers)
    resp = await post_event(client, user, event(med["id"]))
    assert resp.status_code == 201


async def test_dose_events_are_immutable(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    created = (await post_event(client, user, event(med["id"]))).json()
    url = f"/v1/dose-events/{created['id']}"
    assert (
        await client.patch(url, json={"type": "skipped"}, headers=user.headers)
    ).status_code == 405
    assert (await client.delete(url, headers=user.headers)).status_code == 405
    async with engine.connect() as conn:
        with pytest.raises(Exception, match="append-only"):
            await conn.execute(text("UPDATE dose_events SET note = 'x'"))
        await conn.rollback()
        with pytest.raises(Exception, match="append-only"):
            await conn.execute(text("DELETE FROM dose_events"))
        await conn.rollback()


async def test_list_dose_events_filters(client: AsyncClient) -> None:
    user = await register(client)
    med_a = await create_medication(client, user)
    med_b = await create_medication(client, user)
    for at in ("2026-10-12T08:00:00Z", "2026-10-13T08:00:00Z", "2026-10-14T08:00:00Z"):
        await post_event(client, user, event(med_a["id"], at=at))
    await post_event(client, user, event(med_b["id"]))

    def ats(resp: Any) -> list[str]:
        return [e["at"][:10] for e in resp.json()["items"]]

    all_a = await client.get(
        "/v1/dose-events", params={"medication_id": med_a["id"]}, headers=user.headers
    )
    assert ats(all_a) == ["2026-10-14", "2026-10-13", "2026-10-12"]
    window = await client.get(
        "/v1/dose-events",
        params={
            "medication_id": med_a["id"],
            "from": "2026-10-13T00:00:00Z",
            "to": "2026-10-14T00:00:00Z",
        },
        headers=user.headers,
    )
    assert ats(window) == ["2026-10-13"]
    by_profile = await client.get(
        "/v1/dose-events",
        params={"profile_id": user.self_profile_id, "limit": 2},
        headers=user.headers,
    )
    assert len(by_profile.json()["items"]) == 2
    too_many = await client.get("/v1/dose-events", params={"limit": 501}, headers=user.headers)
    assert too_many.status_code == 422


async def test_dose_events_idor(client: AsyncClient) -> None:
    alice = await register(client)
    bob = await register(client)
    med = await create_medication(client, alice)
    alice_event = (await post_event(client, alice, event(med["id"]))).json()

    # Bob cannot record against Alice's medication...
    assert (await post_event(client, bob, event(med["id"]))).status_code == 404
    # ...nor read her events, nor replay her event id.
    assert (
        await client.get(f"/v1/dose-events/{alice_event['id']}", headers=bob.headers)
    ).status_code == 404
    listed = await client.get(
        "/v1/dose-events", params={"medication_id": med["id"]}, headers=bob.headers
    )
    assert listed.json()["items"] == []
    bob_med = await create_medication(client, bob)
    replay = await post_event(client, bob, event(bob_med["id"], id=alice_event["id"]))
    assert replay.status_code == 409


def test_occurrence_key_validation_round_trips_through_the_engine() -> None:
    from datetime import date

    from app.domain.schedule import occurrence_key
    from app.schemas.entities import validate_occurrence_key

    sid = str(uuid.uuid4())
    key = occurrence_key(sid, date(2026, 3, 29), "02:30")
    assert validate_occurrence_key(key) == key
    with pytest.raises(ValueError, match="canonical"):
        validate_occurrence_key(key.upper())


async def test_schedule_ids_must_be_canonical(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    upper = str(uuid.uuid4()).upper()
    resp = await client.post(
        f"/v1/medications/{med['id']}/schedules",
        json={"id": upper, "rule": daily_rule()},
        headers=user.headers,
    )
    assert resp.status_code == 422
    resp = await client.post(
        "/v1/sync/push",
        json={
            "mutations": [
                {
                    "entity": "schedule",
                    "op": "upsert",
                    "id": upper,
                    "data": {"medication_id": med["id"], "rule": daily_rule()},
                    "client_updated_at": "2026-10-01T00:00:00Z",
                }
            ]
        },
        headers=user.device("d"),
    )
    assert resp.status_code == 422
