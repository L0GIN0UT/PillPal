"""The Redis run lock: ``SET NX PX`` with a token-checked release."""

from __future__ import annotations

from collections.abc import AsyncIterator

import pytest_asyncio
from redis.asyncio import Redis

from app.redis_lock import try_lock
from tests.conftest import TEST_REDIS_URL


@pytest_asyncio.fixture
async def redis() -> AsyncIterator[Redis]:
    client: Redis = Redis.from_url(TEST_REDIS_URL)
    await client.flushdb()
    yield client
    await client.flushdb()
    await client.aclose()


async def test_only_one_holder_at_a_time_and_release_frees_it(redis: Redis) -> None:
    async with try_lock(redis, "x", 5000) as first:
        assert first is True
        async with try_lock(redis, "x", 5000) as second:
            assert second is False
        assert await redis.exists("lock:x") == 1  # the loser did not release the winner's lock
    assert await redis.exists("lock:x") == 0
    async with try_lock(redis, "x", 5000) as again:
        assert again is True


async def test_release_never_deletes_a_lock_that_expired_and_was_taken_by_another(
    redis: Redis,
) -> None:
    async with try_lock(redis, "x", 5000) as held:
        assert held
        await redis.delete("lock:x")  # as if the TTL ran out ...
        await redis.set("lock:x", "someone-else", px=5000)  # ... and another run took over
    assert await redis.get("lock:x") == b"someone-else"


async def test_the_lock_expires_by_itself(redis: Redis) -> None:
    async with try_lock(redis, "x", 5000) as held:
        assert held
        assert 0 < await redis.pttl("lock:x") <= 5000
