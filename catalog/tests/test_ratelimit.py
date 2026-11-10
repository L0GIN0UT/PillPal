from __future__ import annotations

from collections.abc import AsyncIterator
from datetime import UTC, datetime

import pytest
from fastapi import Depends, FastAPI
from httpx import ASGITransport, AsyncClient
from redis.asyncio import Redis

from catalog.main import create_app
from catalog.ratelimit import RateLimiter, rate_limited
from tests.conftest import TEST_REDIS_URL, make_settings

INSTALL_A = "install-aaaaaaaaaaaaaaaa"
INSTALL_B = "install-bbbbbbbbbbbbbbbb"


async def _client(**overrides: object) -> AsyncIterator[AsyncClient]:
    settings = make_settings(
        rate_limit_ip_max=4, rate_limit_install_max=2, rate_limit_window_seconds=60, **overrides
    )
    app: FastAPI = create_app(settings)

    @app.post("/_probe/limited", dependencies=[Depends(rate_limited)])
    async def limited() -> dict[str, str]:
        return {"status": "ok"}

    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as c:
            yield c


@pytest.fixture
async def limited(clean_redis: None) -> AsyncIterator[AsyncClient]:
    async for c in _client():
        yield c


async def test_install_bucket_blocks_after_the_limit_with_the_envelope(
    limited: AsyncClient,
) -> None:
    for _ in range(2):
        assert (
            await limited.post("/_probe/limited", headers={"X-Catalog-Install": INSTALL_A})
        ).status_code == 200
    blocked = await limited.post("/_probe/limited", headers={"X-Catalog-Install": INSTALL_A})
    assert blocked.status_code == 429
    assert blocked.json()["error"]["code"] == "rate_limited"
    assert 0 < int(blocked.headers["retry-after"]) <= 60
    other = await limited.post("/_probe/limited", headers={"X-Catalog-Install": INSTALL_B})
    assert other.status_code == 200


async def test_ip_bucket_blocks_rotating_install_ids(limited: AsyncClient) -> None:
    for i in range(4):
        r = await limited.post(
            "/_probe/limited", headers={"X-Catalog-Install": f"install-{i:016d}"}
        )
        assert r.status_code == 200
    blocked = await limited.post(
        "/_probe/limited", headers={"X-Catalog-Install": "install-fresh-0000000"}
    )
    assert blocked.status_code == 429


async def test_malformed_install_header_falls_back_to_the_ip_bucket(limited: AsyncClient) -> None:
    statuses = [
        (
            await limited.post("/_probe/limited", headers={"X-Catalog-Install": "bad id!"})
        ).status_code
        for _ in range(5)
    ]
    assert statuses == [200, 200, 200, 200, 429]


async def test_redis_keys_hold_no_raw_identifiers_and_expire(limited: AsyncClient) -> None:
    await limited.post("/_probe/limited", headers={"X-Catalog-Install": INSTALL_A})
    redis: Redis = Redis.from_url(TEST_REDIS_URL)
    try:
        keys = [k.decode() async for k in redis.scan_iter("*")]
        assert keys
        for key in keys:
            assert INSTALL_A not in key
            assert "127.0.0.1" not in key
            assert 0 < await redis.ttl(key) <= 60
    finally:
        await redis.aclose()


async def test_fails_open_when_redis_is_down() -> None:
    # Nothing listens on port 1: a real connection failure.
    async for c in _client(redis_url="redis://127.0.0.1:1/0"):
        for _ in range(6):
            r = await c.post("/_probe/limited", headers={"X-Catalog-Install": INSTALL_A})
            assert r.status_code == 200


class FakeMonotonic:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


async def test_unavailable_redis_opens_a_breaker_and_logs_once_per_interval(
    capsys: pytest.CaptureFixture[str],
) -> None:
    settings = make_settings(redis_url="redis://127.0.0.1:1/0", rate_limit_unavailable_seconds=30)
    clock = FakeMonotonic()
    redis = Redis.from_url(settings.redis_url, socket_connect_timeout=1, socket_timeout=1)
    limiter = RateLimiter(redis, settings, clock=clock)
    try:
        capsys.readouterr()
        await limiter.check("203.0.113.9", INSTALL_A)  # the failed attempt, logged
        for _ in range(50):  # breaker open: no Redis round trips, no log lines
            await limiter.check("203.0.113.9", INSTALL_A)
        assert capsys.readouterr().out.count("rate_limiter_unavailable") == 1
        clock.now += 31  # half-open: one more attempt, one more line
        await limiter.check("203.0.113.9", INSTALL_A)
        assert capsys.readouterr().out.count("rate_limiter_unavailable") == 1
    finally:
        await redis.aclose()


class FakeWallClock:
    def __init__(self, now: datetime) -> None:
        self.now = now

    def __call__(self) -> datetime:
        return self.now


async def _bucket_keys(redis: Redis) -> set[str]:
    return {k.decode() for k in await redis.keys("rl:*")}


async def test_bucket_names_rotate_daily_and_stay_stable_within_a_day(clean_redis: None) -> None:
    # ADR 0011 section 2: the key behind the bucket names changes every UTC day, so a bucket name
    # seen on one day cannot be matched to the same address on another day.
    settings = make_settings()
    clock = FakeWallClock(datetime(2026, 11, 10, 0, 5, tzinfo=UTC))
    redis = Redis.from_url(TEST_REDIS_URL)
    limiter = RateLimiter(redis, settings, now=clock)
    try:
        await limiter.check("203.0.113.9", None)
        clock.now = datetime(2026, 11, 10, 23, 55, tzinfo=UTC)
        await limiter.check("203.0.113.9", None)
        assert len(await _bucket_keys(redis)) == 1  # same day, same bucket
        clock.now = datetime(2026, 11, 11, 0, 1, tzinfo=UTC)
        await limiter.check("203.0.113.9", None)
        assert len(await _bucket_keys(redis)) == 2  # next day, a different name
    finally:
        await redis.aclose()


async def test_daily_key_depends_on_the_salt(clean_redis: None) -> None:
    clock = FakeWallClock(datetime(2026, 11, 10, 12, 0, tzinfo=UTC))
    redis = Redis.from_url(TEST_REDIS_URL)
    try:
        for salt in ("first-salt-first-salt", "other-salt-other-salt"):
            await RateLimiter(redis, make_settings(rate_limit_salt=salt), now=clock).check(
                "203.0.113.9", None
            )
        assert len(await _bucket_keys(redis)) == 2
    finally:
        await redis.aclose()
