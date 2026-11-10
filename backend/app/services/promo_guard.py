"""Brute-force protection of the promo redeem endpoint (ADR 0018 section 4).

Everything lives in Redis under ``rl:promo:`` and fails closed: when Redis cannot be reached the
caller gets 503 ``promo_unavailable`` and no lookup happens. Keys hold SHA-256 hashes of ids and
addresses (pseudonymised, not anonymous: an address can be hashed and compared), never a code.
Needs Redis 7.0 or newer for ``EXPIRE ... NX``.

``check`` order: per-account attempt bucket, per-address bucket, then the daily failure slot
(lockout), then the breaker. The slot is **reserved atomically** in ``check`` (``INCR`` +
``EXPIRE NX`` + ``TTL`` in one MULTI), so concurrent wrong guesses of one account cannot exceed
``PROMO_MAX_FAILED_PER_DAY``: over the maximum the slot is given back and the answer is 429. The
slot stays taken when the code is rejected and is released (``release``) on every other outcome.
A rejection also counts globally (``record_failure``). The breaker is an alert: more than
``PROMO_BREAKER_THRESHOLD`` failures over all accounts in the window log ``promo_breaker_tripped``
and, for the block period, refuse callers that already failed today; nobody else is blocked.
"""

from __future__ import annotations

import hashlib
import uuid

from redis.asyncio import Redis
from redis.exceptions import RedisError

from app.config import Settings
from app.errors import AppError
from app.observability import get_logger

_log = get_logger("pillpal.promo")

GLOBAL_FAILURES_KEY = "rl:promo:global"
BREAKER_BLOCK_KEY = "rl:promo:blocked"


def bucket_key(kind: str, subject: str) -> str:
    return f"rl:promo:{kind}:{hashlib.sha256(subject.encode()).hexdigest()[:32]}"


def unavailable() -> AppError:
    return AppError(503, "promo_unavailable", "Promo codes are temporarily unavailable")


class PromoGuard:
    def __init__(self, redis: Redis, settings: Settings) -> None:
        self._redis = redis
        self._settings = settings

    async def check(self, user_id: uuid.UUID, ip: str) -> None:
        """Reserve a failure slot, or raise 429 ``rate_limited`` / ``promo_locked`` or 503."""
        s = self._settings
        try:
            await self._attempt("user", str(user_id), s.promo_rate_limit_per_user)
            await self._attempt("ip", ip, s.promo_rate_limit_per_ip)
            slot, ttl, blocked = await self._reserve_slot(user_id)
        except (RedisError, OSError):
            _log.warning("promo_guard_unavailable")
            raise unavailable() from None
        if slot > s.promo_max_failed_per_day:
            await self.release(user_id)
            retry_after = ttl if ttl > 0 else s.promo_lockout_window_seconds
            raise AppError(
                429,
                "promo_locked",
                "Too many wrong codes, try again later",
                headers={"Retry-After": str(retry_after)},
            )
        if blocked and slot >= 2:  # a failure today besides this attempt
            await self.release(user_id)
            raise unavailable()

    async def release(self, user_id: uuid.UUID) -> None:
        """Give the slot back (best effort): the attempt was not a rejected code."""
        key = bucket_key("fail", str(user_id))
        try:
            if await self._redis.decr(key) <= 0:
                await self._redis.delete(key)
        except (RedisError, OSError):
            _log.warning("promo_guard_unavailable")

    async def record_failure(self) -> None:
        """Count a rejected code globally; must run before the failure is answered."""
        s = self._settings
        try:
            async with self._redis.pipeline(transaction=True) as pipe:
                pipe.incr(GLOBAL_FAILURES_KEY)
                pipe.expire(GLOBAL_FAILURES_KEY, s.promo_breaker_window_seconds, nx=True)
                results = await pipe.execute()
            total = int(results[0])
            if total > s.promo_breaker_threshold and await self._redis.set(
                BREAKER_BLOCK_KEY, "1", ex=s.promo_breaker_block_seconds, nx=True
            ):
                _log.error(
                    "promo_breaker_tripped",
                    failures=total,
                    threshold=s.promo_breaker_threshold,
                    window_seconds=s.promo_breaker_window_seconds,
                    block_seconds=s.promo_breaker_block_seconds,
                )
        except (RedisError, OSError):
            _log.warning("promo_guard_unavailable")
            raise unavailable() from None

    async def _attempt(self, kind: str, subject: str, limit: int) -> None:
        key = bucket_key(kind, subject)
        window = self._settings.promo_rate_limit_window_seconds
        async with self._redis.pipeline(transaction=True) as pipe:
            pipe.incr(key)
            pipe.expire(key, window, nx=True)
            pipe.ttl(key)
            results = await pipe.execute()
        if int(results[0]) > limit:
            ttl = int(results[2])
            raise AppError(
                429,
                "rate_limited",
                "Too many attempts, try again later",
                headers={"Retry-After": str(ttl if ttl > 0 else window)},
            )

    async def _reserve_slot(self, user_id: uuid.UUID) -> tuple[int, int, bool]:
        key = bucket_key("fail", str(user_id))
        async with self._redis.pipeline(transaction=True) as pipe:
            pipe.incr(key)
            pipe.expire(key, self._settings.promo_lockout_window_seconds, nx=True)
            pipe.ttl(key)
            pipe.exists(BREAKER_BLOCK_KEY)
            slot, _, ttl, blocked = await pipe.execute()
        return int(slot), int(ttl), bool(blocked)
