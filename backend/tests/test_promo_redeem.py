"""``POST /v1/me/promo/redeem`` (ADR 0018 section 4): the gate and the happy path."""

from __future__ import annotations

import uuid
from datetime import timedelta

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from app.domain.promo import group_code
from tests.conftest import FakeClock
from tests.helpers import register
from tests.promo_helpers import (
    URL,
    activations_of,
    entitlements_of,
    insert_code,
    redeem,
    redemptions_of,
)

pytestmark = pytest.mark.usefixtures("promo_on")

DAY = timedelta(days=1)


# --- the gate: feature flag, authentication, body -----------------------------------------------


async def test_the_feature_is_off_by_default(
    client: AsyncClient, engine: AsyncEngine, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "feature_promo_codes", False)
    user, promo = await register(client), await insert_code(engine)
    resp = await redeem(client, user, promo.code)
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "feature_disabled"
    assert await activations_of(engine, promo) == 0
    assert await entitlements_of(engine, user) == []


async def test_it_needs_a_signed_in_account(client: AsyncClient, engine: AsyncEngine) -> None:
    promo = await insert_code(engine)
    resp = await client.post(URL, json={"code": promo.code})
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "unauthorized"
    bad = await client.post(
        URL, json={"code": promo.code}, headers={"Authorization": "Bearer nonsense"}
    )
    assert bad.status_code == 401
    assert await activations_of(engine, promo) == 0


@pytest.mark.parametrize(
    "body",
    [
        {},
        {"code": ""},
        {"code": "A" * 65},
        {"code": 12345},
        {"code": None},
        {"code": "ABCD", "extra": 1},
        {"promo": "ABCD"},
    ],
)
async def test_a_malformed_body_is_a_validation_error(client: AsyncClient, body: object) -> None:
    user = await register(client)
    resp = await client.post(URL, json=body, headers=user.headers)
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "validation_error"


async def test_a_validation_error_does_not_echo_the_code(client: AsyncClient) -> None:
    user = await register(client)
    secret = "SYNTHETICSECRETCODE" * 4
    resp = await client.post(URL, json={"code": secret, "extra": 1}, headers=user.headers)
    assert resp.status_code == 422
    assert secret not in resp.text


# --- the happy path -----------------------------------------------------------------------------


async def test_a_code_grants_its_entitlement_and_returns_the_state(
    client: AsyncClient, engine: AsyncEngine, clock: FakeClock
) -> None:
    user, promo = await register(client), await insert_code(engine, kind="limits_lifted")
    resp = await redeem(client, user, promo.code)

    assert resp.status_code == 200, resp.text
    assert resp.headers["cache-control"] == "private, no-store"
    body = resp.json()
    assert (body["ads_removed"], body["limits_lifted"]) == (False, True)
    [item] = body["items"]
    assert (item["kind"], item["source"], item["expires_at"]) == ("limits_lifted", "promo", None)
    assert set(item) == {"id", "kind", "source", "granted_at", "expires_at"}
    [row] = await entitlements_of(engine, user)
    assert str(row["id"]) == item["id"]
    assert row["source_ref"] == promo.id  # the code's id, never the code
    assert row["granted_at"] == clock.now
    [redemption] = await redemptions_of(engine, promo)
    assert redemption["user_id"] == uuid.UUID(user.id)
    assert redemption["entitlement_id"] == row["id"]
    assert redemption["redeemed_at"] == clock.now
    assert await activations_of(engine, promo) == 1
    # The state is the one GET /v1/me/entitlements reports.
    again = await client.get("/v1/me/entitlements", headers=user.headers)
    assert again.json()["items"] == body["items"]


async def test_the_entitlement_expires_grant_days_after_the_redemption(
    client: AsyncClient, engine: AsyncEngine, clock: FakeClock
) -> None:
    user, promo = await register(client), await insert_code(engine, grant_days=30)
    resp = await redeem(client, user, promo.code)
    assert resp.status_code == 200
    [row] = await entitlements_of(engine, user)
    assert row["expires_at"] == clock.now + timedelta(days=30)
    clock.advance(days=30, seconds=-1)
    assert (await client.get("/v1/me/entitlements", headers=user.headers)).json()["ads_removed"]
    clock.advance(seconds=1)
    assert not (await client.get("/v1/me/entitlements", headers=user.headers)).json()["ads_removed"]


@pytest.mark.parametrize(
    "typed",
    [
        lambda code: group_code(code),
        lambda code: group_code(code).lower(),
        lambda code: f"  {code.lower()}  ",
        lambda code: " ".join(code[i : i + 5] for i in range(0, len(code), 5)),
    ],
)
async def test_the_code_may_be_typed_grouped_spaced_or_in_lower_case(
    client: AsyncClient, engine: AsyncEngine, typed: object
) -> None:
    user, promo = await register(client), await insert_code(engine)
    resp = await redeem(client, user, typed(promo.code))  # type: ignore[operator]
    assert resp.status_code == 200, resp.text
    assert await activations_of(engine, promo) == 1


async def test_a_code_with_several_activations_serves_that_many_accounts(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    promo = await insert_code(engine, max_activations=2)
    users = [await register(client) for _ in range(3)]
    codes = [(await redeem(client, user, promo.code)).status_code for user in users]
    assert codes == [200, 200, 400]
    assert await activations_of(engine, promo) == 2
    assert await entitlements_of(engine, users[2]) == []


async def test_a_redemption_does_not_touch_other_accounts(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    mine, other = await register(client), await register(client)
    promo = await insert_code(engine, max_activations=5)
    await redeem(client, mine, promo.code)
    body = (await client.get("/v1/me/entitlements", headers=other.headers)).json()
    assert body["items"] == []
    assert await entitlements_of(engine, other) == []
