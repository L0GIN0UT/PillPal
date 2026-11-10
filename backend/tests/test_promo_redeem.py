"""``POST /v1/me/promo/redeem`` (ADR 0018 section 4) on real PostgreSQL and Redis."""

from __future__ import annotations

import asyncio
import json
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.config import Settings
from app.domain.promo import group_code
from app.services.promo import RedeemOutcome, redeem_code
from app.services.promo_guard import BREAKER_BLOCK_KEY, GLOBAL_FAILURES_KEY, bucket_key
from tests.conftest import FakeClock
from tests.entitlement_helpers import insert_entitlement
from tests.grace_helpers import app_of, request_deletion
from tests.helpers import User, register
from tests.promo_helpers import (
    INVALID,
    KEY,
    OTHER_KEY,
    UNKNOWN_CODE,
    URL,
    Promo,
    activations_of,
    insert_code,
    redeem,
    table_rows,
)

pytestmark = pytest.mark.usefixtures("promo_on")

DAY = timedelta(days=1)


async def entitlements_of(engine: AsyncEngine, user: User) -> list[dict[str, object]]:
    return await table_rows(
        engine,
        "SELECT id, kind, source, source_ref, granted_at, expires_at, revoked_at "
        "FROM entitlements WHERE user_id = :u ORDER BY granted_at",
        u=uuid.UUID(user.id),
    )


async def redemptions_of(engine: AsyncEngine, promo: Promo) -> list[dict[str, object]]:
    return await table_rows(
        engine, "SELECT * FROM promo_redemptions WHERE code_id = :c", c=promo.id
    )


def redis_of(client: AsyncClient) -> Redis:
    redis: Redis = app_of(client).state.redis
    return redis


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


# --- concurrency --------------------------------------------------------------------------------


async def test_the_last_activation_cannot_be_taken_twice(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    users = [await register(client) for _ in range(5)]
    for round_ in range(3):
        promo = await insert_code(engine, max_activations=1)
        results = await asyncio.gather(*(redeem(client, user, promo.code) for user in users))
        statuses = sorted(r.status_code for r in results)
        assert statuses == [200] + [400] * (len(users) - 1), round_
        assert await activations_of(engine, promo) == 1
        assert len(await redemptions_of(engine, promo)) == 1
    granted = await table_rows(
        engine, "SELECT count(*) AS n FROM entitlements WHERE source = 'promo'"
    )
    assert granted[0]["n"] == 3


async def test_the_last_of_several_activations_is_taken_once(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    users = [await register(client) for _ in range(5)]
    promo = await insert_code(engine, max_activations=3)
    results = await asyncio.gather(*(redeem(client, user, promo.code) for user in users))
    assert sorted(r.status_code for r in results) == [200, 200, 200, 400, 400]
    assert await activations_of(engine, promo) == 3


async def test_a_double_submit_of_one_account_grants_once(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user, promo = await register(client), await insert_code(engine, max_activations=5)
    results = await asyncio.gather(*(redeem(client, user, promo.code) for _ in range(4)))
    assert [r.status_code for r in results] == [200] * 4
    assert len(await entitlements_of(engine, user)) == 1
    assert await activations_of(engine, promo) == 1


# --- lockout, breaker, rate limits (the order is covered in test_promo_guard) -------------------


async def test_five_failures_lock_the_account_for_the_day_even_for_a_valid_code(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user, promo = await register(client), await insert_code(engine)
    for _ in range(5):
        assert (await redeem(client, user, UNKNOWN_CODE)).status_code == 400
    locked = await redeem(client, user, promo.code)
    assert locked.status_code == 429
    assert locked.json()["error"]["code"] == "promo_locked"
    assert 0 < int(locked.headers["retry-after"]) <= 24 * 3600
    assert await activations_of(engine, promo) == 0
    # The locked attempt is not a further failure; a neighbour is not locked.
    assert int(await redis_of(client).get(bucket_key("fail", user.id))) == 5
    assert (await redeem(client, await register(client), promo.code)).status_code == 200
    await redis_of(client).delete(bucket_key("fail", user.id))
    assert (await redeem(client, user, promo.code)).status_code == 400  # taken by the neighbour


async def test_the_failure_is_counted_before_the_response_is_sent(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    resp = await redeem(client, user, UNKNOWN_CODE)
    assert resp.status_code == 400
    redis = redis_of(client)
    key = bucket_key("fail", user.id)
    assert int(await redis.get(key)) == 1
    assert 0 < await redis.ttl(key) <= 24 * 3600
    assert int(await redis.get(GLOBAL_FAILURES_KEY)) == 1
    assert 0 < await redis.ttl(GLOBAL_FAILURES_KEY) <= 3600


async def test_the_breaker_is_an_alert_and_blocks_only_callers_who_failed_today(
    client: AsyncClient,
    engine: AsyncEngine,
    settings: Settings,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(settings, "promo_breaker_threshold", 3)
    failed, clean = await register(client), await register(client)
    promo = await insert_code(engine, max_activations=5)
    for _ in range(4):
        await redeem(client, failed, UNKNOWN_CODE)
    assert await redis_of(client).exists(BREAKER_BLOCK_KEY) == 1
    assert capsys.readouterr().out.count("promo_breaker_tripped") == 1

    assert (await redeem(client, clean, promo.code)).status_code == 200  # not blocked
    blocked = await redeem(client, failed, promo.code)
    assert blocked.status_code == 503
    assert blocked.json()["error"]["code"] == "promo_unavailable"
    assert await activations_of(engine, promo) == 1
    await redis_of(client).delete(BREAKER_BLOCK_KEY)
    assert (await redeem(client, failed, promo.code)).status_code == 200


async def test_the_per_account_rate_limit(
    client: AsyncClient, engine: AsyncEngine, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "promo_rate_limit_per_user", 2)
    user, promo = await register(client), await insert_code(engine)
    assert (await redeem(client, user, promo.code)).status_code == 200
    assert (await redeem(client, user, promo.code)).status_code == 200  # a replay counts as well
    limited = await redeem(client, user, promo.code)
    assert limited.status_code == 429
    assert limited.json()["error"]["code"] == "rate_limited"
    assert int(limited.headers["retry-after"]) > 0
    assert (await redeem(client, await register(client), UNKNOWN_CODE)).status_code == 400


async def test_the_per_address_rate_limit_is_shared_by_accounts(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "promo_rate_limit_per_ip", 2)
    users = [await register(client) for _ in range(3)]
    statuses = [(await redeem(client, u, UNKNOWN_CODE)).status_code for u in users]
    assert statuses == [400, 400, 429]


# --- fail closed --------------------------------------------------------------------------------


async def test_without_a_reachable_redis_nothing_is_looked_up(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user, promo = await register(client), await insert_code(engine)
    app = app_of(client)
    dead: Redis = Redis.from_url(
        "redis://127.0.0.1:1/0", socket_connect_timeout=0.2, socket_timeout=0.2
    )
    # Restored by hand: pytest's monkeypatch cannot undo an attribute of Starlette's State.
    live = app.state.redis
    app.state.redis = dead
    try:
        resp = await redeem(client, user, promo.code)
    finally:
        app.state.redis = live
        await dead.aclose()
    assert resp.status_code == 503
    assert resp.json()["error"]["code"] == "promo_unavailable"
    assert await activations_of(engine, promo) == 0
    assert await entitlements_of(engine, user) == []


async def test_without_a_key_in_development_the_answer_is_unavailable(
    client: AsyncClient,
    engine: AsyncEngine,
    settings: Settings,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    user, promo = await register(client), await insert_code(engine)
    monkeypatch.setattr(settings, "promo_code_hmac_key", None)
    resp = await redeem(client, user, promo.code)
    assert resp.status_code == 503
    assert resp.json()["error"]["code"] == "promo_unavailable"
    assert await activations_of(engine, promo) == 0


# --- accounts -----------------------------------------------------------------------------------


async def test_an_account_waiting_for_deletion_cannot_redeem(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user, promo = await register(client), await insert_code(engine)
    assert (await request_deletion(client, user)).status_code == 204
    resp = await redeem(client, user, promo.code)
    assert resp.status_code == 401
    assert await activations_of(engine, promo) == 0


async def test_an_account_that_became_pending_after_authentication_is_refused_under_the_lock(
    client: AsyncClient, engine: AsyncEngine, maker: async_sessionmaker[AsyncSession]
) -> None:
    user, promo = await register(client), await insert_code(engine)
    assert (await request_deletion(client, user)).status_code == 204
    async with maker() as session:
        outcome = await redeem_code(session, uuid.UUID(user.id), promo.code, KEY, datetime.now(UTC))
    assert outcome is RedeemOutcome.ACCOUNT_GONE
    assert await activations_of(engine, promo) == 0
