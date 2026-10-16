"""Device records are capped per user (X-Device-ID is client-chosen)."""

from __future__ import annotations

import uuid

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from tests.helpers import register
from tests.sync_helpers import push_as, scoped_pull
from tests.test_sync import med_data, mut


async def device_count(engine: AsyncEngine, user_id: str) -> int:
    async with engine.connect() as conn:
        return int(
            (
                await conn.execute(
                    text("SELECT count(*) FROM devices WHERE user_id = :u"), {"u": user_id}
                )
            ).scalar_one()
        )


async def test_a_pull_from_a_new_device_over_the_cap_is_refused(
    client: AsyncClient, engine: AsyncEngine, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "max_devices_per_user", 2)
    user = await register(client)
    cursors = {user.self_profile_id: 0}
    for device in ("dev-a", "dev-b"):
        await scoped_pull(client, user, cursors, device=device)
    refused = await scoped_pull(client, user, cursors, device="dev-c", expect=409)
    assert refused["error"]["code"] == "too_many_devices"
    assert await device_count(engine, user.id) == 2


async def test_a_known_device_keeps_working_at_the_cap(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "max_devices_per_user", 1)
    user = await register(client)
    cursors = {user.self_profile_id: 0}
    await scoped_pull(client, user, cursors, device="dev-a")
    await scoped_pull(client, user, cursors, device="dev-a")


async def test_a_push_from_a_new_device_over_the_cap_is_refused_whole(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "max_devices_per_user", 1)
    user = await register(client)
    data = med_data(user.self_profile_id)
    await push_as(client, user, [mut("medication", "upsert", str(uuid.uuid4()), data)], "dev-a")
    mutation = mut("medication", "upsert", str(uuid.uuid4()), data)
    resp = await client.post(
        "/v1/sync/push", json={"mutations": [mutation]}, headers=user.device("dev-b")
    )
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "too_many_devices"


async def test_devices_not_seen_for_a_long_time_make_room(
    client: AsyncClient, engine: AsyncEngine, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "max_devices_per_user", 2)
    user = await register(client)
    cursors = {user.self_profile_id: 0}
    for device in ("old-1", "old-2"):
        await scoped_pull(client, user, cursors, device=device)
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "UPDATE devices SET last_seen_at = now() - interval '400 days' "
                "WHERE user_id = :u AND device_id = 'old-1'"
            ),
            {"u": user.id},
        )
    await scoped_pull(client, user, cursors, device="fresh")
    async with engine.connect() as conn:
        left = {
            r[0]
            for r in await conn.execute(
                text("SELECT device_id FROM devices WHERE user_id = :u"), {"u": user.id}
            )
        }
    assert left == {"old-2", "fresh"}


async def test_other_users_do_not_count_against_the_cap(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "max_devices_per_user", 1)
    first, second = await register(client), await register(client)
    await scoped_pull(client, first, {first.self_profile_id: 0}, device="shared-id")
    await scoped_pull(client, second, {second.self_profile_id: 0}, device="shared-id")
