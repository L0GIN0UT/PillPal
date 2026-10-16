"""Medication stock baseline ``stock_set_at`` (TZ §2.4, docs/adr/0004-stock-tracking.md)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import create_medication, register
from tests.test_sync import med_data, mut, pull, push

SET_AT = "2026-10-10T09:30:00.123456+00:00"


async def test_rest_roundtrip_keeps_the_baseline_instant(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(
        client,
        user,
        stock_count="30",
        stock_unit="tablet",
        stock_set_at="2026-10-10T12:30:00.123456+03:00",
    )
    # Stored and echoed in UTC with microseconds (the client's conflict precision).
    assert med["stock_set_at"] == "2026-10-10T09:30:00.123456Z"

    url = f"/v1/medications/{med['id']}"
    patched = await client.patch(url, json={"notes": "after meals"}, headers=user.headers)
    assert patched.status_code == 200, patched.text
    assert patched.json()["stock_set_at"] == "2026-10-10T09:30:00.123456Z"

    refilled = await client.patch(
        url,
        json={"stock_count": "60", "stock_set_at": "2026-10-12T08:00:00+00:00"},
        headers=user.headers,
    )
    assert Decimal(refilled.json()["stock_count"]) == 60
    assert refilled.json()["stock_set_at"] == "2026-10-12T08:00:00Z"

    cleared = await client.patch(
        url, json={"stock_count": None, "stock_set_at": None}, headers=user.headers
    )
    assert cleared.json()["stock_set_at"] is None


async def test_without_baseline_it_stays_null(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user, stock_count="30")
    assert med["stock_set_at"] is None


@pytest.mark.parametrize(
    "value",
    [
        "2026-10-10T09:30:00",  # naive: the zone is required
        "not a date",
        (datetime.now(UTC) + timedelta(days=1)).isoformat(),  # beyond the allowed skew
    ],
)
async def test_invalid_baseline_is_422(client: AsyncClient, value: str) -> None:
    user = await register(client)
    resp = await client.post(
        f"/v1/profiles/{user.self_profile_id}/medications",
        json={"id": str(uuid.uuid4()), "name": "Aspirin", "stock_set_at": value},
        headers=user.headers,
    )
    assert resp.status_code == 422, resp.text


async def test_sync_push_and_pull_carry_the_baseline(client: AsyncClient) -> None:
    user = await register(client)
    mid = str(uuid.uuid4())
    data = med_data(
        user.self_profile_id, stock_count="12.5", stock_unit="tablet", stock_set_at=SET_AT
    )
    results = await push(client, user, "phone", [mut("medication", "upsert", mid, data)])
    assert results[0]["status"] == "applied"

    changes: list[dict[str, Any]] = (await pull(client, user))["changes"]
    pulled = next(c for c in changes if c["entity"] == "medication")
    assert pulled["data"]["stock_set_at"] == "2026-10-10T09:30:00.123456Z"
    assert Decimal(pulled["data"]["stock_count"]) == Decimal("12.5")

    # Replaying the same full state is a no-op (no new version).
    again = await push(client, user, "phone", [mut("medication", "upsert", mid, data)])
    assert again[0]["version"] == results[0]["version"]


async def test_tombstone_erases_the_baseline(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    med = await create_medication(client, user, stock_count="30", stock_set_at=SET_AT)
    assert (
        await client.delete(f"/v1/medications/{med['id']}", headers=user.headers)
    ).status_code == 204
    async with engine.connect() as conn:
        row = (
            await conn.execute(
                text("SELECT stock_set_at, deleted_at FROM medications WHERE id = :i"),
                {"i": med["id"]},
            )
        ).one()
    assert row.deleted_at is not None
    assert row.stock_set_at is None


async def test_schema_rejects_a_baseline_on_a_tombstone(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    async with engine.connect() as conn:
        with pytest.raises(Exception, match="tombstone_erased"):
            await conn.execute(
                text(
                    "UPDATE medications SET name = NULL, deleted_at = now(), "
                    "stock_set_at = now() WHERE id = :i"
                ),
                {"i": med["id"]},
            )
