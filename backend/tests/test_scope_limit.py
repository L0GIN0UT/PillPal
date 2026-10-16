"""``max_access_scopes_per_user`` also bounds the managed profiles a user creates."""

from __future__ import annotations

import asyncio
import uuid

import pytest
from httpx import AsyncClient

from app.config import Settings
from tests.helpers import register
from tests.sync_helpers import outcome, push_as
from tests.test_sync import mut


def profile_body() -> dict[str, str]:
    return {"id": str(uuid.uuid4()), "display_name": "Synthetic Ward", "timezone": "UTC"}


async def test_creating_a_managed_profile_over_the_limit_is_refused(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "max_access_scopes_per_user", 2)  # own profile + one
    user = await register(client)
    first = await client.post("/v1/profiles", json=profile_body(), headers=user.headers)
    assert first.status_code == 201
    second = await client.post("/v1/profiles", json=profile_body(), headers=user.headers)
    assert (second.status_code, second.json()["error"]["code"]) == (409, "too_many_scopes")


async def test_a_sync_push_creating_a_profile_over_the_limit_is_rejected(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "max_access_scopes_per_user", 2)
    user = await register(client)
    data = {"kind": "managed", "display_name": "Synthetic Ward", "timezone": "UTC"}
    results = await push_as(
        client,
        user,
        [mut("profile", "upsert", str(uuid.uuid4()), data) for _ in range(2)],
    )
    assert [outcome(r) for r in results] == [("applied", None), ("rejected", "too_many_scopes")]


async def test_updating_an_existing_profile_is_not_a_creation(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "max_access_scopes_per_user", 2)
    user = await register(client)
    pid = str(uuid.uuid4())
    data = {"kind": "managed", "display_name": "Synthetic Ward", "timezone": "UTC"}
    await push_as(client, user, [mut("profile", "upsert", pid, data)])
    again = await push_as(
        client, user, [mut("profile", "upsert", pid, data | {"display_name": "Renamed"}, 1)]
    )
    assert outcome(again[0]) == ("applied", None)


async def test_concurrent_creations_cannot_exceed_the_limit(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "max_access_scopes_per_user", 3)  # own profile + two
    user = await register(client)
    results = await asyncio.gather(
        *[client.post("/v1/profiles", json=profile_body(), headers=user.headers) for _ in range(4)]
    )
    assert sorted(r.status_code for r in results) == [201, 201, 409, 409]
