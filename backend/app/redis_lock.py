"""A best-effort mutual-exclusion lock on Redis: ``SET NX PX`` and a token-checked release.

Used to keep one ``deliver_pushes`` run at a time (ADR 0008 §6). It is an optimisation of
at-least-once delivery, not its safety net: correctness still rests on the row claim and the
fencing of recorded results, because a lock can expire under a stalled holder. The TTL bounds
how long a crashed holder blocks the next runs; the release deletes the key only while it
still holds this holder's token, so an expired lock taken over by another run is left alone.
"""

from __future__ import annotations

import secrets
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from redis.asyncio import Redis

KEY_PREFIX = "lock:"
_RELEASE = (
    "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) "
    "else return 0 end"
)


@asynccontextmanager
async def try_lock(redis: Redis, name: str, ttl_milliseconds: int) -> AsyncIterator[bool]:
    """Yield whether the lock ``name`` was acquired; releases it on exit when it was."""
    key = KEY_PREFIX + name
    token = secrets.token_hex(16)
    acquired = bool(await redis.set(key, token, nx=True, px=ttl_milliseconds))
    try:
        yield acquired
    finally:
        if acquired:
            await redis.eval(_RELEASE, 1, key, token)  # type: ignore[misc]
