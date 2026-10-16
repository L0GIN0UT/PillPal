"""Profile missed-dose alert settings (TZ §2.5): REST, sync keep-on-absent, DB checks."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import User, register
from tests.test_sync import pull, push


async def get_self(client: AsyncClient, user: User) -> dict[str, Any]:
    resp = await client.get(f"/v1/profiles/{user.self_profile_id}", headers=user.headers)
    assert resp.status_code == 200
    return dict(resp.json())


async def patch_self(client: AsyncClient, user: User, body: dict[str, Any]) -> Any:
    return await client.patch(
        f"/v1/profiles/{user.self_profile_id}", json=body, headers=user.headers
    )


async def test_new_profiles_alert_after_30_minutes_by_default(client: AsyncClient) -> None:
    user = await register(client)
    profile = await get_self(client, user)
    assert profile["missed_alert_minutes"] == 30
    assert profile["missed_alerts_enabled"] is True


async def test_patch_changes_only_the_fields_sent(client: AsyncClient) -> None:
    user = await register(client)
    resp = await patch_self(client, user, {"missed_alert_minutes": 45})
    assert resp.status_code == 200
    assert (resp.json()["missed_alert_minutes"], resp.json()["missed_alerts_enabled"]) == (45, True)

    resp = await patch_self(client, user, {"missed_alerts_enabled": False})
    assert (resp.json()["missed_alert_minutes"], resp.json()["missed_alerts_enabled"]) == (
        45,
        False,
    )  # False is a value, not "absent"

    before = await get_self(client, user)
    resp = await patch_self(client, user, {"display_name": "Synthetic Name"})
    assert resp.json()["missed_alert_minutes"] == before["missed_alert_minutes"]
    assert resp.json()["missed_alerts_enabled"] is False


@pytest.mark.parametrize("minutes", [5, 30, 720])
async def test_patch_accepts_the_range_bounds(client: AsyncClient, minutes: int) -> None:
    user = await register(client)
    resp = await patch_self(client, user, {"missed_alert_minutes": minutes})
    assert resp.status_code == 200
    assert resp.json()["missed_alert_minutes"] == minutes


@pytest.mark.parametrize("value", [4, 0, -1, 721, True, "30", 30.5, None])
async def test_patch_rejects_out_of_range_or_mistyped_minutes(
    client: AsyncClient, value: Any
) -> None:
    user = await register(client)
    resp = await patch_self(client, user, {"missed_alert_minutes": value})
    if value is None:  # null means absent, as for the other optional profile fields
        assert resp.status_code == 200
        assert resp.json()["missed_alert_minutes"] == 30
    else:
        assert resp.status_code == 422
        assert (await get_self(client, user))["missed_alert_minutes"] == 30


async def test_patch_rejects_a_non_boolean_enabled_flag(client: AsyncClient) -> None:
    user = await register(client)
    for value in ("yes", 1, "false"):
        assert (await patch_self(client, user, {"missed_alerts_enabled": value})).status_code == 422


async def test_alert_settings_belong_to_the_owner(client: AsyncClient) -> None:
    owner, stranger = await register(client), await register(client)
    resp = await client.patch(
        f"/v1/profiles/{owner.self_profile_id}",
        json={"missed_alert_minutes": 10},
        headers=stranger.headers,
    )
    assert resp.status_code == 404
    assert (await client.patch(f"/v1/profiles/{owner.self_profile_id}", json={})).status_code == 401


# --- sync ---------------------------------------------------------------------------------


def mut(
    entity: str, op: str, id_: str, data: dict[str, Any] | None = None, minutes: int = 0
) -> dict[str, Any]:
    """A mutation stamped relative to now: self profiles carry a server-clock key."""
    stamp = datetime.now(UTC) + timedelta(minutes=minutes)
    return {
        "entity": entity,
        "op": op,
        "id": id_,
        "data": data,
        "client_updated_at": stamp.isoformat(),
    }


def profile_data(**extra: Any) -> dict[str, Any]:
    return {"kind": "self", "display_name": "Synthetic Name", "timezone": "Europe/Samara", **extra}


async def test_sync_push_without_the_fields_keeps_the_stored_values(client: AsyncClient) -> None:
    user = await register(client)
    await patch_self(client, user, {"missed_alert_minutes": 90, "missed_alerts_enabled": False})
    [result] = await push(
        client,
        user,
        "phone",
        [mut("profile", "upsert", user.self_profile_id, profile_data(), minutes=5)],
    )
    assert result["status"] == "applied"
    stored = await get_self(client, user)
    assert (stored["missed_alert_minutes"], stored["missed_alerts_enabled"]) == (90, False)


async def test_sync_push_with_the_fields_sets_them_and_pull_returns_them(
    client: AsyncClient,
) -> None:
    user = await register(client)
    data = profile_data(missed_alert_minutes=15, missed_alerts_enabled=False)
    [result] = await push(
        client, user, "phone", [mut("profile", "upsert", user.self_profile_id, data, minutes=5)]
    )
    assert result["status"] == "applied"
    page = await pull(client, user)
    change = next(c for c in page["changes"] if c["entity"] == "profile" and c["seq"] > 1)
    assert change["data"]["missed_alert_minutes"] == 15
    assert change["data"]["missed_alerts_enabled"] is False


async def test_sync_push_replay_is_idempotent_with_the_fields(client: AsyncClient) -> None:
    user = await register(client)
    batch = [
        mut(
            "profile",
            "upsert",
            user.self_profile_id,
            profile_data(missed_alert_minutes=15),
            minutes=5,
        )
    ]
    first = await push(client, user, "phone", batch)
    second = await push(client, user, "phone", batch)
    assert first[0]["status"] == second[0]["status"] == "applied"
    assert first[0]["version"] == second[0]["version"]


async def test_a_new_managed_profile_can_carry_the_settings(client: AsyncClient) -> None:
    user = await register(client)
    pid = str(uuid.uuid4())
    data = {"display_name": "Synthetic Ward", "timezone": "UTC", "missed_alert_minutes": 120}
    [result] = await push(client, user, "phone", [mut("profile", "upsert", pid, data)])
    assert result["status"] == "applied"
    resp = await client.get(f"/v1/profiles/{pid}", headers=user.headers)
    assert resp.json()["missed_alert_minutes"] == 120
    assert resp.json()["missed_alerts_enabled"] is True


@pytest.mark.parametrize(
    "extra",
    [{"missed_alert_minutes": 4}, {"missed_alert_minutes": 721}, {"missed_alerts_enabled": 1}],
)
async def test_sync_push_rejects_invalid_settings(
    client: AsyncClient, extra: dict[str, Any]
) -> None:
    user = await register(client)
    [result] = await push(
        client,
        user,
        "phone",
        [mut("profile", "upsert", user.self_profile_id, profile_data(**extra), minutes=5)],
    )
    assert (result["status"], result["code"]) == ("rejected", "validation_error")


async def test_a_stale_push_returns_the_current_settings(client: AsyncClient) -> None:
    user = await register(client)
    await push(
        client,
        user,
        "phone",
        [
            mut(
                "profile",
                "upsert",
                user.self_profile_id,
                profile_data(missed_alert_minutes=60),
                minutes=5,
            )
        ],
    )
    [stale] = await push(
        client,
        user,
        "tablet",
        [mut("profile", "upsert", user.self_profile_id, profile_data(), minutes=-5)],
    )
    assert stale["status"] == "ignored_stale"
    assert stale["current"]["data"]["missed_alert_minutes"] == 60


async def test_the_database_enforces_the_range(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    async with engine.connect() as conn:
        for bad in (4, 721):
            with pytest.raises(Exception, match="missed_alert_minutes"):
                await conn.execute(
                    text("UPDATE profiles SET missed_alert_minutes = :m WHERE id = :p"),
                    {"m": bad, "p": user.self_profile_id},
                )
            await conn.rollback()


async def test_rest_create_accepts_the_settings_like_sync(client: AsyncClient) -> None:
    user = await register(client)
    pid = str(uuid.uuid4())
    resp = await client.post(
        "/v1/profiles",
        json={
            "id": pid,
            "display_name": "Synthetic Ward",
            "timezone": "UTC",
            "missed_alert_minutes": 90,
            "missed_alerts_enabled": False,
        },
        headers=user.headers,
    )
    assert resp.status_code == 201
    assert (resp.json()["missed_alert_minutes"], resp.json()["missed_alerts_enabled"]) == (
        90,
        False,
    )
    plain = await client.post(
        "/v1/profiles",
        json={"id": str(uuid.uuid4()), "display_name": "Other Ward", "timezone": "UTC"},
        headers=user.headers,
    )
    assert (plain.json()["missed_alert_minutes"], plain.json()["missed_alerts_enabled"]) == (
        30,
        True,
    )
    for bad in (
        {"missed_alert_minutes": 4},
        {"missed_alert_minutes": True},
        {"missed_alerts_enabled": 1},
    ):
        resp = await client.post(
            "/v1/profiles",
            json={"id": str(uuid.uuid4()), "display_name": "X", "timezone": "UTC", **bad},
            headers=user.headers,
        )
        assert resp.status_code == 422
