"""The JWKS cache (ADR 0017 section 3): fetched once, kept for the TTL, refreshed once on an
unknown ``kid``, 503 when the provider cannot be asked. No database, no Redis."""

from __future__ import annotations

from datetime import timedelta

import httpx
import pytest

from app.errors import AppError
from app.oauth.jwks import JwksCache
from tests.oauth_real_helpers import EC_KEY, NOW, OTHER_RSA_KEY, RSA_KEY, JwksServer, timeout

URL = "https://keys.example/jwks"
TTL = 3600
COOLDOWN = 30


def cache_for(server: JwksServer, *, timeout_seconds: float = 10) -> JwksCache:
    http = httpx.AsyncClient(transport=httpx.MockTransport(server.handler), timeout=timeout_seconds)
    return JwksCache(URL, http, ttl_seconds=TTL, refresh_cooldown_seconds=COOLDOWN)


async def test_a_known_kid_is_found_and_the_keys_are_cached() -> None:
    server = JwksServer()
    cache = cache_for(server)
    assert await cache.key_for("k1", NOW) is not None
    assert await cache.key_for("k1", NOW + timedelta(seconds=TTL - 1)) is not None
    assert server.requests == 1


async def test_the_cache_expires_after_the_ttl() -> None:
    server = JwksServer()
    cache = cache_for(server)
    await cache.key_for("k1", NOW)
    await cache.key_for("k1", NOW + timedelta(seconds=TTL))
    assert server.requests == 2


async def test_an_unknown_kid_refetches_once_and_then_finds_a_rotated_key() -> None:
    server = JwksServer()
    cache = cache_for(server)
    await cache.key_for("k1", NOW)
    server.keys["k2"] = OTHER_RSA_KEY
    later = NOW + timedelta(seconds=COOLDOWN)
    assert await cache.key_for("k2", later) is not None
    assert server.requests == 2


async def test_an_unknown_kid_refetches_once_and_is_then_refused() -> None:
    server = JwksServer()
    cache = cache_for(server)
    await cache.key_for("k1", NOW)
    assert await cache.key_for("nope", NOW + timedelta(seconds=COOLDOWN)) is None
    assert server.requests == 2


async def test_unknown_kids_cannot_hammer_the_provider() -> None:
    server = JwksServer()
    cache = cache_for(server)
    await cache.key_for("k1", NOW)
    for attempt in range(1, 6):
        await cache.key_for(f"nope-{attempt}", NOW + timedelta(seconds=attempt))
    assert server.requests == 1  # inside the cooldown no refetch happens


async def test_an_unknown_kid_on_a_cold_cache_fetches_only_once() -> None:
    server = JwksServer()
    assert await cache_for(server).key_for("nope", NOW) is None
    assert server.requests == 1


async def test_a_timeout_is_provider_unreachable() -> None:
    server = JwksServer()
    server.fail = timeout
    with pytest.raises(AppError) as info:
        await cache_for(server).key_for("k1", NOW)
    assert (info.value.status_code, info.value.code) == (503, "provider_unreachable")


@pytest.mark.parametrize(
    "response",
    [
        httpx.Response(500),
        httpx.Response(200, text="not json"),
        httpx.Response(200, json=["no", "object"]),
        httpx.Response(200, json={"keys": "nope"}),
        httpx.Response(302, headers={"location": "https://evil.example/"}),
    ],
)
async def test_a_broken_answer_is_provider_unreachable(response: httpx.Response) -> None:
    server = JwksServer()
    server.fail = lambda _request: response
    with pytest.raises(AppError) as info:
        await cache_for(server).key_for("k1", NOW)
    assert info.value.code == "provider_unreachable"


async def test_unusable_keys_are_skipped_not_fatal() -> None:
    server = JwksServer()
    plain = JwksServer({"k1": RSA_KEY, "ec": EC_KEY})

    def with_junk(request: httpx.Request) -> httpx.Response:
        response = plain.handler(request)
        keys = response.json()["keys"] + [{"kty": "oct", "kid": "sym", "k": "AAAA"}, {"kid": "x"}]
        return httpx.Response(200, json={"keys": keys})

    server.fail = with_junk
    cache = cache_for(server)
    assert await cache.key_for("k1", NOW) is not None
    assert await cache.key_for("ec", NOW) is not None
    assert await cache.key_for("sym", NOW) is None
