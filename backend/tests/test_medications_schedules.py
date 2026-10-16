"""Medications and schedules CRUD, validation, versioning and IDOR protection."""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import create_medication, create_schedule, daily_rule, register


async def test_medication_crud_roundtrip(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    med = await create_medication(
        client,
        user,
        tz_mode="fixed",
        fixed_tz="Europe/Moscow",
        stock_count="30",
        stock_unit="tablet",
        low_stock_days=5,
        privacy="anonymous",
    )
    assert med["profile_id"] == user.self_profile_id
    assert med["version"] == 1
    assert med["fixed_tz"] == "Europe/Moscow"
    assert med["privacy"] == "anonymous"

    listed = await client.get(
        f"/v1/profiles/{user.self_profile_id}/medications", headers=user.headers
    )
    assert [m["id"] for m in listed.json()["items"]] == [med["id"]]

    url = f"/v1/medications/{med['id']}"
    patched = await client.patch(
        url, json={"tz_mode": "local", "fixed_tz": None, "notes": None}, headers=user.headers
    )
    assert patched.status_code == 200, patched.text
    assert patched.json()["tz_mode"] == "local"
    assert patched.json()["notes"] is None
    assert patched.json()["name"] == "Aspirin"
    assert patched.json()["version"] == 2

    assert (await client.delete(url, headers=user.headers)).status_code == 204
    assert (await client.get(url, headers=user.headers)).status_code == 404
    # Soft delete: the row is a tombstone, not gone.
    async with engine.connect() as conn:
        row = (
            await conn.execute(
                text("SELECT deleted_at, version FROM medications WHERE id = :id"),
                {"id": med["id"]},
            )
        ).one()
    assert row.deleted_at is not None
    assert row.version == 3


@pytest.mark.parametrize(
    "overrides",
    [
        {"name": ""},
        {"name": "x" * 201},
        {"tz_mode": "fixed", "fixed_tz": None},
        {"tz_mode": "local", "fixed_tz": "Europe/Moscow"},
        {"tz_mode": "fixed", "fixed_tz": "Nowhere/City"},
        {"privacy": "public"},
        {"stock_count": "-1"},
        {"low_stock_days": 1000},
        {"version": 7},
        {"profile_id": str(uuid.uuid4())},
        {"id": "not-a-uuid"},
    ],
)
async def test_medication_validation(client: AsyncClient, overrides: dict[str, Any]) -> None:
    user = await register(client)
    payload = {
        "id": str(uuid.uuid4()),
        "name": "Aspirin",
        "tz_mode": "local",
        "privacy": "shared",
        **overrides,
    }
    resp = await client.post(
        f"/v1/profiles/{user.self_profile_id}/medications", json=payload, headers=user.headers
    )
    assert resp.status_code == 422, resp.text


async def test_medication_patch_revalidates_merged_state(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    url = f"/v1/medications/{med['id']}"
    resp = await client.patch(url, json={"tz_mode": "fixed"}, headers=user.headers)
    assert resp.status_code == 422
    resp = await client.patch(url, json={"name": None}, headers=user.headers)
    assert resp.status_code == 422
    resp = await client.patch(url, json={}, headers=user.headers)
    assert resp.status_code == 200
    assert resp.json()["version"] == 1


async def test_schedule_crud_and_canonical_rule(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    rule = {
        "v": 1,
        "kind": "weekdays",
        "start_date": "2026-10-16",
        "weekdays": [5, 1, 3],
        "times": [
            {"time": "20:00", "dose": {"amount": "0.50", "unit": "tablet"}},
            {"time": "08:00", "dose": {"amount": "1", "unit": "tablet"}},
        ],
    }
    sched = await create_schedule(client, user, med["id"], rule)
    assert sched["medication_id"] == med["id"]
    assert sched["rule"]["weekdays"] == [1, 3, 5]
    assert [t["time"] for t in sched["rule"]["times"]] == ["08:00", "20:00"]
    assert sched["rule"]["times"][1]["dose"]["amount"] == "0.5"
    assert sched["rule"]["end_date"] is None

    listed = await client.get(f"/v1/medications/{med['id']}/schedules", headers=user.headers)
    assert [s["id"] for s in listed.json()["items"]] == [sched["id"]]

    url = f"/v1/schedules/{sched['id']}"
    upd = await client.patch(
        url, json={"rule": daily_rule(("09:00", "21:00"))}, headers=user.headers
    )
    assert upd.status_code == 200
    assert upd.json()["version"] == 2
    assert upd.json()["rule"]["kind"] == "daily"
    assert (await client.get(url, headers=user.headers)).json()["version"] == 2

    assert (await client.delete(url, headers=user.headers)).status_code == 204
    assert (await client.get(url, headers=user.headers)).status_code == 404
    assert (await client.delete(url, headers=user.headers)).status_code == 204


@pytest.mark.parametrize(
    "rule",
    [
        {"v": 2, "kind": "daily", "start_date": "2026-10-16", "times": []},
        {"v": 1, "kind": "daily", "start_date": "2026-10-16", "times": []},
        {"v": 1, "kind": "hourly", "start_date": "2026-10-16", "times": []},
        {
            "v": 1,
            "kind": "interval_days",
            "start_date": "2026-10-16",
            "interval_days": 1,
            "times": [{"time": "08:00", "dose": {"amount": "1", "unit": "tablet"}}],
        },
        {"v": 1, "kind": "as_needed", "start_date": "2026-02-30", "times": []},
    ],
)
async def test_invalid_rule_is_422_with_location(client: AsyncClient, rule: dict[str, Any]) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    resp = await client.post(
        f"/v1/medications/{med['id']}/schedules",
        json={"id": str(uuid.uuid4()), "rule": rule},
        headers=user.headers,
    )
    assert resp.status_code == 422
    details = resp.json()["error"]["details"]
    assert all(d["loc"][:2] == ["body", "rule"] for d in details)


async def test_schedule_update_with_invalid_rule(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    sched = await create_schedule(client, user, med["id"])
    resp = await client.patch(
        f"/v1/schedules/{sched['id']}", json={"rule": {"v": 1}}, headers=user.headers
    )
    assert resp.status_code == 422


async def test_deleting_medication_tombstones_its_schedules(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    sched = await create_schedule(client, user, med["id"])
    await client.delete(f"/v1/medications/{med['id']}", headers=user.headers)
    assert (
        await client.get(f"/v1/schedules/{sched['id']}", headers=user.headers)
    ).status_code == 404
    resp = await client.post(
        f"/v1/medications/{med['id']}/schedules",
        json={"id": str(uuid.uuid4()), "rule": daily_rule()},
        headers=user.headers,
    )
    assert resp.status_code == 404


async def test_idor_medications_and_schedules_are_404(client: AsyncClient) -> None:
    alice = await register(client)
    bob = await register(client)
    med = await create_medication(client, alice)
    sched = await create_schedule(client, alice, med["id"])

    requests: list[tuple[str, str, dict[str, Any] | None]] = [
        ("GET", f"/v1/profiles/{alice.self_profile_id}/medications", None),
        (
            "POST",
            f"/v1/profiles/{alice.self_profile_id}/medications",
            {"id": str(uuid.uuid4()), "name": "Evil"},
        ),
        ("GET", f"/v1/medications/{med['id']}", None),
        ("PATCH", f"/v1/medications/{med['id']}", {"name": "pwned"}),
        ("DELETE", f"/v1/medications/{med['id']}", None),
        ("GET", f"/v1/medications/{med['id']}/schedules", None),
        (
            "POST",
            f"/v1/medications/{med['id']}/schedules",
            {"id": str(uuid.uuid4()), "rule": daily_rule()},
        ),
        ("GET", f"/v1/schedules/{sched['id']}", None),
        ("PATCH", f"/v1/schedules/{sched['id']}", {"rule": daily_rule(("03:00",))}),
        ("DELETE", f"/v1/schedules/{sched['id']}", None),
    ]
    for method, url, body in requests:
        resp = await client.request(method, url, json=body, headers=bob.headers)
        assert resp.status_code == 404, (method, url, resp.text)
        assert resp.json() == {"error": {"code": "not_found", "message": "Not found"}}

    # Alice's data is untouched.
    assert (await client.get(f"/v1/medications/{med['id']}", headers=alice.headers)).json()[
        "name"
    ] == "Aspirin"
    assert (await client.get(f"/v1/schedules/{sched['id']}", headers=alice.headers)).json()[
        "version"
    ] == 1


async def test_unknown_ids_are_404(client: AsyncClient) -> None:
    user = await register(client)
    for url in (
        f"/v1/medications/{uuid.uuid4()}",
        f"/v1/schedules/{uuid.uuid4()}",
        f"/v1/profiles/{uuid.uuid4()}/medications",
    ):
        assert (await client.get(url, headers=user.headers)).status_code == 404
    assert (await client.get("/v1/medications/nope", headers=user.headers)).status_code == 422
