"""Refresh rotation is idempotent for a short window (ADR 0001 addendum, plan 3.7).

A background isolate can lose the response of a rotation (process killed, network drop) and
retry with the same old token. From the same device within ``REFRESH_REUSE_WINDOW_SECONDS``
that returns the very same new pair; from another device, after the window, or without the
cached pair, it is reuse and revokes the family.
"""

from __future__ import annotations

import asyncio
import hashlib
import secrets
from typing import Any

from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.services.refresh_reuse import RefreshReuse
from tests.conftest import TEST_REDIS_URL, FakeClock
from tests.helpers import DEFAULT_PASSWORD, register_unverified, verify

DEVICE_A = {"X-Device-ID": "dev-a"}
DEVICE_B = {"X-Device-ID": "dev-b"}
WINDOW = 120


async def _login_on_device(client: AsyncClient) -> dict[str, Any]:
    email = await register_unverified(client, password=DEFAULT_PASSWORD)
    return await verify(client, email, headers=DEVICE_A)


async def _refresh(client: AsyncClient, token: str, headers: dict[str, str] | None = None) -> Any:
    return await client.post(
        "/v1/auth/refresh", json={"refresh_token": token}, headers=headers or {}
    )


async def test_same_device_repeat_within_window_returns_the_same_pair(
    client: AsyncClient,
) -> None:
    old = (await _login_on_device(client))["refresh_token"]
    first = await _refresh(client, old, DEVICE_A)
    again = await _refresh(client, old, DEVICE_A)
    assert first.status_code == again.status_code == 200
    assert again.json() == first.json()
    # The family is alive: the pair works, and rotating it goes on as usual.
    onward = await _refresh(client, first.json()["refresh_token"], DEVICE_A)
    assert onward.status_code == 200
    assert onward.json()["refresh_token"] != first.json()["refresh_token"]


async def test_the_window_answers_once_then_it_is_reuse(client: AsyncClient) -> None:
    old = (await _login_on_device(client))["refresh_token"]
    first = await _refresh(client, old, DEVICE_A)
    assert (await _refresh(client, old, DEVICE_A)).json() == first.json()

    third = await _refresh(client, old, DEVICE_A)

    assert third.status_code == 401
    assert third.json()["error"]["code"] == "token_reused"
    assert (await _refresh(client, first.json()["refresh_token"], DEVICE_A)).status_code == 401


async def test_the_pair_is_bound_to_the_device_that_rotated(client: AsyncClient) -> None:
    """A token issued without a device is rotated by dev-a: only dev-a may repeat it."""
    email = await register_unverified(client)
    old = (await verify(client, email))["refresh_token"]
    first = await _refresh(client, old, DEVICE_A)
    assert (await _refresh(client, old, DEVICE_B)).json()["error"]["code"] == "token_reused"
    other = await register_unverified(client)
    old2 = (await verify(client, other))["refresh_token"]
    first2 = await _refresh(client, old2, DEVICE_A)
    assert (await _refresh(client, old2, DEVICE_A)).json() == first2.json()
    assert first.status_code == 200


async def test_concurrent_duplicate_rotation_gets_one_pair(client: AsyncClient) -> None:
    old = (await _login_on_device(client))["refresh_token"]
    a, b = await asyncio.gather(_refresh(client, old, DEVICE_A), _refresh(client, old, DEVICE_A))
    assert a.status_code == b.status_code == 200
    assert a.json() == b.json()


async def test_other_device_within_window_is_reuse(client: AsyncClient) -> None:
    old = (await _login_on_device(client))["refresh_token"]
    rotated = (await _refresh(client, old, DEVICE_A)).json()["refresh_token"]
    stolen = await _refresh(client, old, DEVICE_B)
    assert stolen.status_code == 401
    assert stolen.json()["error"]["code"] == "token_reused"
    assert (await _refresh(client, rotated, DEVICE_A)).status_code == 401


async def test_replay_without_device_header_is_reuse(client: AsyncClient) -> None:
    old = (await _login_on_device(client))["refresh_token"]
    rotated = (await _refresh(client, old, DEVICE_A)).json()["refresh_token"]
    replay = await _refresh(client, old)
    assert replay.status_code == 401
    assert replay.json()["error"]["code"] == "token_reused"
    assert (await _refresh(client, rotated, DEVICE_A)).status_code == 401


async def test_rotation_without_any_device_never_gets_a_window(client: AsyncClient) -> None:
    email = await register_unverified(client)
    old = (await verify(client, email))["refresh_token"]
    await _refresh(client, old)
    replay = await _refresh(client, old)
    assert replay.json()["error"]["code"] == "token_reused"


async def test_repeat_after_the_window_is_reuse(client: AsyncClient, clock: FakeClock) -> None:
    old = (await _login_on_device(client))["refresh_token"]
    rotated = (await _refresh(client, old, DEVICE_A)).json()["refresh_token"]
    clock.advance(seconds=WINDOW + 1)
    replay = await _refresh(client, old, DEVICE_A)
    assert replay.status_code == 401
    assert replay.json()["error"]["code"] == "token_reused"
    assert (await _refresh(client, rotated, DEVICE_A)).status_code == 401


async def test_repeat_just_inside_the_window_still_works(
    client: AsyncClient, clock: FakeClock
) -> None:
    old = (await _login_on_device(client))["refresh_token"]
    first = await _refresh(client, old, DEVICE_A)
    clock.advance(seconds=WINDOW - 1)
    assert (await _refresh(client, old, DEVICE_A)).json() == first.json()


async def test_repeat_after_the_pair_was_already_rotated_is_reuse(client: AsyncClient) -> None:
    """A lost response never saw the new pair; if that pair moved on, the repeat is not a retry."""
    old = (await _login_on_device(client))["refresh_token"]
    first = (await _refresh(client, old, DEVICE_A)).json()
    onward = await _refresh(client, first["refresh_token"], DEVICE_A)
    assert onward.status_code == 200

    replay = await _refresh(client, old, DEVICE_A)

    assert replay.status_code == 401
    assert replay.json()["error"]["code"] == "token_reused"
    assert (await _refresh(client, onward.json()["refresh_token"], DEVICE_A)).status_code == 401


async def test_missing_cache_entry_fails_closed_as_reuse(client: AsyncClient) -> None:
    old = (await _login_on_device(client))["refresh_token"]
    rotated = (await _refresh(client, old, DEVICE_A)).json()["refresh_token"]
    redis: Redis = Redis.from_url(TEST_REDIS_URL)
    await redis.flushdb()
    await redis.aclose()
    replay = await _refresh(client, old, DEVICE_A)
    assert replay.json()["error"]["code"] == "token_reused"
    assert (await _refresh(client, rotated, DEVICE_A)).status_code == 401


async def test_replay_after_logout_is_refused(client: AsyncClient) -> None:
    old = (await _login_on_device(client))["refresh_token"]
    rotated = (await _refresh(client, old, DEVICE_A)).json()["refresh_token"]
    await client.post("/v1/auth/logout", json={"refresh_token": rotated})
    replay = await _refresh(client, old, DEVICE_A)
    assert replay.status_code == 401


async def test_replay_of_expired_token_is_refused(client: AsyncClient, engine: AsyncEngine) -> None:
    old = (await _login_on_device(client))["refresh_token"]
    await _refresh(client, old, DEVICE_A)
    async with engine.begin() as conn:
        await conn.execute(text("UPDATE refresh_tokens SET expires_at = now() - interval '1s'"))
    assert (await _refresh(client, old, DEVICE_A)).status_code == 401


async def test_cached_pair_is_encrypted_under_a_key_from_the_old_token(
    client: AsyncClient,
) -> None:
    old = (await _login_on_device(client))["refresh_token"]
    pair = (await _refresh(client, old, DEVICE_A)).json()
    redis: Redis = Redis.from_url(TEST_REDIS_URL)
    keys = [k.decode() for k in await redis.keys("rr:*")]
    assert keys == ["rr:" + hashlib.sha256(old.encode()).hexdigest()]
    raw: bytes = await redis.get(keys[0])
    ttl = await redis.ttl(keys[0])
    await redis.aclose()
    assert 0 < ttl <= WINDOW
    for secret in (pair["refresh_token"], pair["access_token"]):
        assert secret.encode() not in raw


# -- RefreshReuse on its own (real Redis, no HTTP) ------------------------------------------


def _reuse(redis_url: str = TEST_REDIS_URL) -> RefreshReuse:
    return RefreshReuse(Redis.from_url(redis_url), WINDOW)


async def test_remember_then_recall_round_trip(clean_state: None) -> None:
    reuse = _reuse()
    old = secrets.token_urlsafe(32)
    await reuse.remember(old, "dev-a", {"access_token": "a", "refresh_token": "r"})
    assert await reuse.recall(old, "dev-a") == {"access_token": "a", "refresh_token": "r"}


async def test_recall_is_single_use(clean_state: None) -> None:
    reuse = _reuse()
    old = secrets.token_urlsafe(32)
    await reuse.remember(old, "dev-a", {"refresh_token": "r"})
    assert await reuse.recall(old, "dev-a") == {"refresh_token": "r"}
    assert await reuse.recall(old, "dev-a") is None


async def test_recall_refuses_another_device_and_a_wrong_token(clean_state: None) -> None:
    reuse = _reuse()
    old = secrets.token_urlsafe(32)
    await reuse.remember(old, "dev-a", {"refresh_token": "r"})
    assert await reuse.recall(old, "dev-b") is None
    assert await reuse.recall(old, None) is None
    assert await reuse.recall(secrets.token_urlsafe(32), "dev-a") is None


async def test_tampered_entry_is_not_returned(clean_state: None) -> None:
    reuse = _reuse()
    old = secrets.token_urlsafe(32)
    await reuse.remember(old, "dev-a", {"refresh_token": "r"})
    redis: Redis = Redis.from_url(TEST_REDIS_URL)
    key = "rr:" + hashlib.sha256(old.encode()).hexdigest()
    raw: bytes = await redis.get(key)
    await redis.set(key, raw[:-1] + bytes([raw[-1] ^ 1]), ex=WINDOW)
    await redis.aclose()
    assert await reuse.recall(old, "dev-a") is None


async def test_a_redis_that_never_answers_is_cut_off_quickly() -> None:
    """The call runs under row locks: a hung Redis must not hold them."""

    async def silent(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        await asyncio.sleep(30)

    server = await asyncio.start_server(silent, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    reuse = RefreshReuse(Redis.from_url(f"redis://127.0.0.1:{port}/0"), WINDOW, timeout_seconds=0.2)
    old = secrets.token_urlsafe(32)
    try:
        started = asyncio.get_running_loop().time()
        await reuse.remember(old, "dev-a", {"refresh_token": "r"})
        assert await reuse.recall(old, "dev-a") is None
        assert asyncio.get_running_loop().time() - started < 2
    finally:
        server.close()


async def test_unreachable_redis_fails_closed_and_never_raises() -> None:
    reuse = _reuse("redis://127.0.0.1:1/0")
    old = secrets.token_urlsafe(32)
    await reuse.remember(old, "dev-a", {"refresh_token": "r"})  # best effort
    assert await reuse.recall(old, "dev-a") is None
