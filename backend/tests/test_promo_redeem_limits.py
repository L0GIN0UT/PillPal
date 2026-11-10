"""Promo redeem: concurrency, lockout, breaker, rate limits, fail closed, accounts."""

from __future__ import annotations

import asyncio
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.config import Settings
from app.services.promo import RedeemOutcome, redeem_code
from app.services.promo_guard import BREAKER_BLOCK_KEY, GLOBAL_FAILURES_KEY, bucket_key
from tests.grace_helpers import request_deletion
from tests.helpers import register
from tests.promo_helpers import (
    KEY,
    UNKNOWN_CODE,
    activations_of,
    entitlements_of,
    insert_code,
    redeem,
    redemptions_of,
    redis_of,
    table_rows,
)

pytestmark = pytest.mark.usefixtures("promo_on")

DAY = timedelta(days=1)


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


async def test_concurrent_wrong_codes_of_one_account_never_exceed_the_daily_maximum(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "promo_rate_limit_per_user", 100)
    monkeypatch.setattr(settings, "promo_rate_limit_per_ip", 100)
    user = await register(client)
    results = await asyncio.gather(*(redeem(client, user, UNKNOWN_CODE) for _ in range(15)))
    wrong = [r for r in results if r.status_code == 400]
    locked = [r for r in results if r.status_code == 429]
    assert len(wrong) == settings.promo_max_failed_per_day  # the slot is reserved, not read
    assert len(wrong) + len(locked) == 15
    assert {r.json()["error"]["code"] for r in locked} == {"promo_locked"}
    assert int(await redis_of(client).get(bucket_key("fail", user.id))) == len(wrong)


async def test_a_successful_or_replayed_redeem_gives_its_slot_back(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user, promo = await register(client), await insert_code(engine)
    await redeem(client, user, UNKNOWN_CODE)  # one failure stays on the account
    key = bucket_key("fail", user.id)
    for _ in range(2):  # redeemed, then replayed
        assert (await redeem(client, user, promo.code)).status_code == 200
        assert int(await redis_of(client).get(key)) == 1


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
    client: AsyncClient, engine: AsyncEngine, request: pytest.FixtureRequest
) -> None:
    user, promo = await register(client), await insert_code(engine)
    request.getfixturevalue("redis_down")  # after the setup, which needs Redis
    resp = await redeem(client, user, promo.code)
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
