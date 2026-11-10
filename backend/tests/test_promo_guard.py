"""The Redis guard of the promo redeem endpoint (ADR 0018 section 4): limits, lockout, breaker.

Real Redis, no database. Every test uses its own random ids, so nothing needs a flush. A failure
slot is reserved by ``check`` and stays taken until ``release``; ``record_failure`` is the global
count of a rejected code.
"""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import AsyncIterator
from typing import Any

import pytest
import pytest_asyncio
from redis.asyncio import Redis
from redis.exceptions import ConnectionError as RedisConnectionError

from app.errors import AppError
from app.observability import configure_logging
from app.services.promo_guard import BREAKER_BLOCK_KEY, GLOBAL_FAILURES_KEY, PromoGuard, bucket_key
from tests.conftest import TEST_REDIS_URL, make_settings

DAY = 24 * 3600


@pytest_asyncio.fixture
async def redis() -> AsyncIterator[Redis]:
    client: Redis = Redis.from_url(TEST_REDIS_URL)
    await client.delete(GLOBAL_FAILURES_KEY, BREAKER_BLOCK_KEY)
    try:
        yield client
    finally:
        await client.delete(GLOBAL_FAILURES_KEY, BREAKER_BLOCK_KEY)
        await client.aclose()


@pytest.fixture(autouse=True)
def _logging() -> None:
    configure_logging("INFO")


def guard_for(redis: Redis, **overrides: object) -> PromoGuard:
    values: dict[str, object] = {"promo_rate_limit_per_user": 1000, "promo_rate_limit_per_ip": 1000}
    return PromoGuard(redis, make_settings(**(values | overrides)))


def new_ip() -> str:
    return f"203.0.113.{uuid.uuid4().hex[:8]}"


async def expect(guard: PromoGuard, user: uuid.UUID, ip: str, status: int, code: str) -> AppError:
    with pytest.raises(AppError) as caught:
        await guard.check(user, ip)
    assert (caught.value.status_code, caught.value.code) == (status, code)
    return caught.value


async def slots(redis: Redis, user: uuid.UUID) -> int:
    return int(await redis.get(bucket_key("fail", str(user))) or 0)


async def test_a_clean_caller_passes(redis: Redis) -> None:
    await guard_for(redis).check(uuid.uuid4(), new_ip())


async def test_keys_hold_hashes_never_ids_or_addresses(redis: Redis) -> None:
    user, ip = uuid.uuid4(), new_ip()
    await guard_for(redis).check(user, ip)
    keys = [bucket_key("user", str(user)), bucket_key("ip", ip), bucket_key("fail", str(user))]
    for key in keys:
        assert await redis.exists(key) == 1
        assert key.startswith("rl:promo:")
        assert str(user) not in key
        assert ip not in key


async def test_the_per_user_limit_counts_attempts_and_names_the_wait(redis: Redis) -> None:
    user, ip = uuid.uuid4(), new_ip()
    guard = guard_for(redis, promo_rate_limit_per_user=2, promo_rate_limit_window_seconds=600)
    await guard.check(user, ip)
    await guard.check(user, ip)
    error = await expect(guard, user, ip, 429, "rate_limited")
    assert error.headers is not None
    assert 0 < int(error.headers["Retry-After"]) <= 600
    await guard.check(uuid.uuid4(), ip)  # another account has its own budget


async def test_the_per_ip_limit_is_shared_by_accounts(redis: Redis) -> None:
    ip = new_ip()
    guard = guard_for(redis, promo_rate_limit_per_ip=2)
    await guard.check(uuid.uuid4(), ip)
    await guard.check(uuid.uuid4(), ip)
    await expect(guard, uuid.uuid4(), ip, 429, "rate_limited")
    await guard.check(uuid.uuid4(), new_ip())


async def test_the_user_limit_is_checked_before_the_address_limit(redis: Redis) -> None:
    user, ip = uuid.uuid4(), new_ip()
    guard = guard_for(redis, promo_rate_limit_per_user=1, promo_rate_limit_per_ip=1)
    await guard.check(user, ip)
    await expect(guard, user, ip, 429, "rate_limited")
    # The second attempt stopped at the user bucket: the address was counted once.
    assert int(await redis.get(bucket_key("ip", ip))) == 1


async def test_a_slot_is_reserved_with_the_window_set_at_once(redis: Redis) -> None:
    user = uuid.uuid4()
    guard = guard_for(redis)
    await guard.check(user, new_ip())
    await guard.check(user, new_ip())
    key = bucket_key("fail", str(user))
    assert int(await redis.get(key)) == 2
    assert 0 < await redis.ttl(key) <= DAY


async def test_the_window_runs_from_the_first_slot(redis: Redis) -> None:
    user = uuid.uuid4()
    guard = guard_for(redis)
    await guard.check(user, new_ip())
    key = bucket_key("fail", str(user))
    await redis.expire(key, 100)
    await guard.check(user, new_ip())
    assert 0 < await redis.ttl(key) <= 100  # a later slot does not extend the window


async def test_release_gives_the_slot_back_and_leaves_no_key_at_zero(redis: Redis) -> None:
    user, guard = uuid.uuid4(), guard_for(redis)
    await guard.check(user, new_ip())
    await guard.check(user, new_ip())
    await guard.release(user)
    assert await slots(redis, user) == 1
    await guard.release(user)
    assert await redis.exists(bucket_key("fail", str(user))) == 0
    await guard.release(user)  # nothing to give back: no negative counter survives
    assert await redis.exists(bucket_key("fail", str(user))) == 0


async def test_the_daily_lockout_starts_beyond_the_limit_and_names_the_wait(redis: Redis) -> None:
    user, ip = uuid.uuid4(), new_ip()
    guard = guard_for(redis, promo_max_failed_per_day=3)
    for _ in range(3):  # three slots are allowed and stay taken (three rejected codes)
        await guard.check(user, ip)
    error = await expect(guard, user, ip, 429, "promo_locked")
    assert error.headers is not None
    assert 0 < int(error.headers["Retry-After"]) <= DAY
    assert await slots(redis, user) == 3  # the refused attempt gave its slot back
    await guard.check(uuid.uuid4(), ip)  # other accounts are not locked


async def test_concurrent_checks_never_hand_out_more_slots_than_the_maximum(redis: Redis) -> None:
    user, ip = uuid.uuid4(), new_ip()
    guard = guard_for(redis, promo_max_failed_per_day=4)
    results = await asyncio.gather(
        *(guard.check(user, ip) for _ in range(20)), return_exceptions=True
    )
    granted = [r for r in results if r is None]
    refused = [r for r in results if isinstance(r, AppError) and r.code == "promo_locked"]
    assert len(granted) == 4
    assert len(refused) == 16
    assert await slots(redis, user) == 4


async def test_the_lockout_ends_with_its_window(redis: Redis) -> None:
    user, ip = uuid.uuid4(), new_ip()
    guard = guard_for(redis, promo_max_failed_per_day=1)
    await guard.check(user, ip)
    await expect(guard, user, ip, 429, "promo_locked")
    await redis.delete(bucket_key("fail", str(user)))
    await guard.check(user, ip)


async def test_a_rejection_counts_globally_with_a_window_set_at_once(redis: Redis) -> None:
    guard = guard_for(redis)
    await guard.record_failure()
    await guard.record_failure()
    assert int(await redis.get(GLOBAL_FAILURES_KEY)) == 2
    assert 0 < await redis.ttl(GLOBAL_FAILURES_KEY) <= 3600


async def test_the_breaker_trips_above_the_threshold_and_logs_once(
    redis: Redis, capsys: pytest.CaptureFixture[str]
) -> None:
    guard = guard_for(redis, promo_breaker_threshold=3)
    for _ in range(3):
        await guard.record_failure()
    assert not await redis.exists(BREAKER_BLOCK_KEY)  # exactly the threshold: not yet
    assert "promo_breaker_tripped" not in capsys.readouterr().out
    await guard.record_failure()
    assert 0 < await redis.ttl(BREAKER_BLOCK_KEY) <= 900
    await guard.record_failure()  # still blocked: no second alert
    assert capsys.readouterr().out.count("promo_breaker_tripped") == 1


async def test_the_breaker_blocks_only_callers_with_a_failure_today(redis: Redis) -> None:
    guard = guard_for(redis, promo_breaker_threshold=1)
    failed, clean, ip = uuid.uuid4(), uuid.uuid4(), new_ip()
    await guard.check(failed, ip)  # an earlier attempt of this account was rejected
    await guard.record_failure()
    await guard.record_failure()
    assert await redis.exists(BREAKER_BLOCK_KEY)
    await guard.check(clean, ip)  # alert-only for everybody else
    await expect(guard, failed, ip, 503, "promo_unavailable")
    assert await slots(redis, failed) == 1  # the blocked attempt gave its slot back
    await redis.delete(BREAKER_BLOCK_KEY)
    await guard.check(failed, ip)


async def test_the_lockout_is_answered_before_the_breaker(redis: Redis) -> None:
    user, ip = uuid.uuid4(), new_ip()
    guard = guard_for(redis, promo_breaker_threshold=1, promo_max_failed_per_day=1)
    await guard.check(user, ip)
    await guard.record_failure()
    await guard.record_failure()
    assert await redis.exists(BREAKER_BLOCK_KEY)
    await expect(guard, user, ip, 429, "promo_locked")


class BrokenRedis:
    """A Redis whose connection is gone: every command fails."""

    def pipeline(self, *args: Any, **kwargs: Any) -> Any:
        raise RedisConnectionError("down")

    async def decr(self, *args: Any, **kwargs: Any) -> Any:
        raise RedisConnectionError("down")


async def test_a_dead_redis_fails_closed_on_check_and_on_failure_counting() -> None:
    guard = PromoGuard(BrokenRedis(), make_settings())  # type: ignore[arg-type]
    user, ip = uuid.uuid4(), new_ip()
    await expect(guard, user, ip, 503, "promo_unavailable")
    with pytest.raises(AppError) as caught:
        await guard.record_failure()
    assert (caught.value.status_code, caught.value.code) == (503, "promo_unavailable")


async def test_release_is_best_effort_when_redis_is_gone() -> None:
    await PromoGuard(BrokenRedis(), make_settings()).release(uuid.uuid4())  # type: ignore[arg-type]
