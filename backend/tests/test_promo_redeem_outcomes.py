"""Promo redeem: one answer for unusable codes, rejections and replays."""

from __future__ import annotations

import json
from datetime import timedelta

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.domain.promo import group_code
from app.services.promo_guard import bucket_key
from tests.conftest import FakeClock
from tests.entitlement_helpers import insert_entitlement
from tests.helpers import register
from tests.promo_helpers import (
    INVALID,
    OTHER_KEY,
    UNKNOWN_CODE,
    activations_of,
    entitlements_of,
    insert_code,
    redeem,
    redemptions_of,
    redis_of,
)

pytestmark = pytest.mark.usefixtures("promo_on")

DAY = timedelta(days=1)


# --- one identical answer for everything that is not a usable code ------------------------------


async def test_every_unusable_code_gets_the_same_400_and_counts_as_a_failure(
    client: AsyncClient, engine: AsyncEngine, clock: FakeClock
) -> None:
    now = clock.now
    unknown = UNKNOWN_CODE
    exhausted = await insert_code(engine, max_activations=1, activations=1)
    disabled = await insert_code(engine, disabled_at=now - DAY)
    expired = await insert_code(engine, expires_at=now - DAY)
    other_region = await insert_code(engine, key=OTHER_KEY)
    cases = {
        "unknown": unknown,
        "exhausted": exhausted.code,
        "disabled": disabled.code,
        "expired": expired.code,
        "other region key": other_region.code,
        "zero and one": "0123456789",
        "letters outside the alphabet": "OILOILOILOILOILOIL",
        "long s": "\u017f" * 20,
        "kelvin": "\u212a" * 20,
        "cyrillic lookalike": "\u0410" * 20,
        "only separators": "- - -",
    }
    redis = redis_of(client)
    seen: list[tuple[int, object, str | None]] = []
    for name, code in cases.items():
        user = await register(client)
        resp = await redeem(client, user, code)
        seen.append((resp.status_code, resp.json(), resp.headers.get("retry-after")))
        assert resp.status_code == 400, name
        assert resp.json() == INVALID, name
        assert await entitlements_of(engine, user) == [], name
        assert int(await redis.get(bucket_key("fail", user.id))) == 1, name
    assert len({json.dumps(body, sort_keys=True) for _, body, _ in seen}) == 1
    assert {retry for _, _, retry in seen} == {None}
    assert await activations_of(engine, exhausted) == 1
    assert await activations_of(engine, expired) == 0


async def test_a_code_is_usable_until_the_instant_it_expires(
    client: AsyncClient, engine: AsyncEngine, clock: FakeClock
) -> None:
    expiry = clock.now + timedelta(hours=1)
    first, second = await register(client), await register(client)
    promo = await insert_code(engine, expires_at=expiry, max_activations=2)
    clock.advance(minutes=59, seconds=59)
    assert (await redeem(client, first, promo.code)).status_code == 200
    clock.advance(seconds=1)  # now == expires_at: expired
    assert (await redeem(client, second, promo.code)).json() == INVALID


async def test_a_rejection_leaves_no_redemption_and_no_activation(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    promo = await insert_code(engine, max_activations=1, activations=1)
    resp = await redeem(client, user, promo.code)
    assert resp.status_code == 400
    assert await redemptions_of(engine, promo) == []  # the redemption insert was rolled back
    assert await activations_of(engine, promo) == 1
    assert await entitlements_of(engine, user) == []


# --- replay -------------------------------------------------------------------------------------


async def test_redeeming_again_replays_the_state_without_a_second_grant(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user, promo = await register(client), await insert_code(engine, max_activations=3)
    first = await redeem(client, user, promo.code)
    second = await redeem(client, user, group_code(promo.code))
    assert (first.status_code, second.status_code) == (200, 200)
    assert second.json()["items"] == first.json()["items"]
    assert len(await entitlements_of(engine, user)) == 1
    assert await activations_of(engine, promo) == 1  # the counter is untouched
    assert len(await redemptions_of(engine, promo)) == 1
    redis = redis_of(client)
    assert await redis.get(bucket_key("fail", user.id)) is None  # a replay is not a failure


async def test_a_replay_never_grants_a_revoked_entitlement_again(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user, promo = await register(client), await insert_code(engine)
    await redeem(client, user, promo.code)
    async with engine.begin() as conn:
        await conn.execute(text("UPDATE entitlements SET revoked_at = now()"))
    resp = await redeem(client, user, promo.code)
    assert resp.status_code == 200
    assert resp.json()["items"] == []
    assert resp.json()["ads_removed"] is False
    [row] = await entitlements_of(engine, user)
    assert row["revoked_at"] is not None
    assert await activations_of(engine, promo) == 1


async def test_a_replay_still_answers_after_the_code_was_disabled(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user, promo = await register(client), await insert_code(engine)
    await redeem(client, user, promo.code)
    async with engine.begin() as conn:
        await conn.execute(text("UPDATE promo_codes SET disabled_at = now()"))
    resp = await redeem(client, user, promo.code)
    assert resp.status_code == 200
    assert resp.json()["ads_removed"] is True


async def test_an_admin_grant_does_not_block_a_redemption(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user, promo = await register(client), await insert_code(engine)
    await insert_entitlement(engine, user.id, "ads_removed", "admin_grant")
    resp = await redeem(client, user, promo.code)
    assert resp.status_code == 200
    assert len(resp.json()["items"]) == 2
