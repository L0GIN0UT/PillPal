"""Idempotent refresh rotation for a short window (ADR 0001 addendum, plan 3.7).

A background isolate may lose the response of a rotation and retry with the same old
refresh token. Instead of reading that as theft, the rotation stores the new pair for
``REFRESH_REUSE_WINDOW_SECONDS`` and a repeat from the *same device* gets it back.

The entry sits in Redis under ``rr:`` + ``sha256(old token)``. The value is AES-GCM
encrypted with a key derived (HKDF-SHA256) from the old token itself, so a Redis dump
reveals no usable token: only a holder of the old token can open it, and the device the
pair was issued to is inside the ciphertext (checked in constant time). It expires with
the window.

Fails closed: whatever goes wrong on the read side (Redis down, entry missing or
tampered, other device) answers ``None`` and the caller treats the repeat as reuse, as
before the window existed. The write side is best effort: rotation never depends on
Redis, a lost entry only means a lost response is revoked as before.
Tokens are never logged.
"""

from __future__ import annotations

import hashlib
import json
import os
from typing import Any

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from redis.asyncio import Redis
from redis.exceptions import RedisError

from app.observability import get_logger
from app.security import constant_time_equals

_log = get_logger("pillpal.refresh_reuse")

KEY_PREFIX = "rr:"
_HKDF_INFO = b"pillpal/refresh-reuse/v1"
_NONCE_BYTES = 12
_KEY_BYTES = 32


def _redis_key(old_token: str) -> str:
    return KEY_PREFIX + hashlib.sha256(old_token.encode()).hexdigest()


def _cipher(old_token: str) -> AESGCM:
    key = HKDF(algorithm=hashes.SHA256(), length=_KEY_BYTES, salt=None, info=_HKDF_INFO).derive(
        old_token.encode()
    )
    return AESGCM(key)


class RefreshReuse:
    def __init__(self, redis: Redis, window_seconds: int) -> None:
        self._redis = redis
        self._window = window_seconds

    async def remember(self, old_token: str, device_id: str | None, pair: dict[str, Any]) -> None:
        """Store the pair issued for ``old_token``; never raises."""
        if device_id is None:
            return  # no device, no window: a repeat could not be tied to the same device
        key = _redis_key(old_token)
        nonce = os.urandom(_NONCE_BYTES)
        plain = json.dumps({"d": device_id, "p": pair}).encode()
        blob = nonce + _cipher(old_token).encrypt(nonce, plain, key.encode())
        try:
            await self._redis.set(key, blob, ex=self._window)
        except (RedisError, OSError):
            _log.warning("refresh_reuse_store_unavailable")

    async def recall(self, old_token: str, device_id: str | None) -> dict[str, Any] | None:
        """The pair issued for ``old_token`` to ``device_id``, else ``None`` (= reuse)."""
        if device_id is None:
            return None
        key = _redis_key(old_token)
        try:
            blob = await self._redis.get(key)
        except (RedisError, OSError):
            _log.warning("refresh_reuse_store_unavailable")
            return None
        if not isinstance(blob, bytes) or len(blob) <= _NONCE_BYTES:
            return None
        try:
            plain = _cipher(old_token).decrypt(
                blob[:_NONCE_BYTES], blob[_NONCE_BYTES:], key.encode()
            )
            stored = json.loads(plain)
            owner, pair = str(stored["d"]), stored["p"]
        except (InvalidTag, ValueError, KeyError, TypeError):
            return None
        if not constant_time_equals(owner, device_id) or not isinstance(pair, dict):
            return None
        return pair
