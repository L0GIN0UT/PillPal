"""``GET /v1/me/entitlements`` (ADR 0018 section 2): the effective state of the caller only."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.entitlement_helpers import insert_entitlement
from tests.grace_helpers import delete_and_restore
from tests.helpers import link_accounts, register
from tests.ward_helpers import make_ward

URL = "/v1/me/entitlements"
HOUR = timedelta(hours=1)


def future() -> datetime:
    return datetime.now(UTC) + HOUR


def past() -> datetime:
    return datetime.now(UTC) - HOUR


async def test_it_needs_a_signed_in_account(client: AsyncClient) -> None:
    resp = await client.get(URL)
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "unauthorized"
    bad = await client.get(URL, headers={"Authorization": "Bearer nonsense"})
    assert bad.status_code == 401


async def test_an_account_without_entitlements_gets_false_and_no_items(
    client: AsyncClient,
) -> None:
    user = await register(client)
    resp = await client.get(URL, headers=user.headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["ads_removed"] is False
    assert body["limits_lifted"] is False
    assert body["items"] == []
    server_time = datetime.fromisoformat(body["server_time"])
    assert abs(datetime.now(UTC) - server_time) < timedelta(minutes=1)


async def test_the_answer_is_private_and_never_cached(client: AsyncClient) -> None:
    user = await register(client)
    resp = await client.get(URL, headers=user.headers)
    assert resp.headers["cache-control"] == "private, no-store"


async def test_effective_state_table(client: AsyncClient, engine: AsyncEngine) -> None:
    """Each account has one row; the answer follows revocation and the exclusive expiry."""
    cases = {
        "open_ended": ({}, True),
        "expires_later": ({"expires_at": future()}, True),
        "expired": ({"granted_at": past() - HOUR, "expires_at": past()}, False),
        "revoked": ({"revoked_at": past()}, False),
        "revoked_and_valid": ({"expires_at": future(), "revoked_at": past()}, False),
    }
    for name, (fields, active) in cases.items():
        user = await register(client)
        await insert_entitlement(engine, user.id, "ads_removed", "promo", **fields)
        body = (await client.get(URL, headers=user.headers)).json()
        assert body["ads_removed"] is active, name
        assert body["limits_lifted"] is False, name
        assert len(body["items"]) == int(active), name


async def test_kinds_are_independent_and_dead_rows_are_not_listed(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    await insert_entitlement(engine, user.id, "ads_removed", "purchase")
    await insert_entitlement(engine, user.id, "limits_lifted", "promo", revoked_at=past())
    dead = await insert_entitlement(
        engine, user.id, "limits_lifted", "admin_grant", granted_at=past() - HOUR, expires_at=past()
    )
    body = (await client.get(URL, headers=user.headers)).json()
    assert body["ads_removed"] is True
    assert body["limits_lifted"] is False
    assert [(i["kind"], i["source"]) for i in body["items"]] == [("ads_removed", "purchase")]
    assert str(dead) not in str(body)
    # Fields of an item: no source reference, no revocation state.
    assert set(body["items"][0]) == {"id", "kind", "source", "granted_at", "expires_at"}


async def test_relatives_and_co_guardians_do_not_inherit(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    ward = await make_ward(client)
    other = await register(client)
    await link_accounts(client, ward.owner, other, "editor")  # a relative of the owner
    await insert_entitlement(engine, ward.owner.id, "ads_removed")
    await insert_entitlement(engine, ward.owner.id, "limits_lifted")

    owner = (await client.get(URL, headers=ward.owner.headers)).json()
    assert owner["ads_removed"] is True
    assert owner["limits_lifted"] is True
    for relative in (ward.first, ward.second, ward.viewer, other):
        body = (await client.get(URL, headers=relative.headers)).json()
        assert body["ads_removed"] is False
        assert body["limits_lifted"] is False
        assert body["items"] == []


async def test_only_the_callers_rows_are_returned(client: AsyncClient, engine: AsyncEngine) -> None:
    first, second = await register(client), await register(client)
    mine = await insert_entitlement(engine, first.id)
    await insert_entitlement(engine, second.id, "limits_lifted")
    body = (await client.get(URL, headers=first.headers)).json()
    assert [item["id"] for item in body["items"]] == [str(mine)]


async def test_a_restored_account_keeps_its_entitlements(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    await insert_entitlement(engine, user.id)
    restored = await delete_and_restore(client, user)
    body = (await client.get(URL, headers=restored.headers)).json()
    assert body["ads_removed"] is True
