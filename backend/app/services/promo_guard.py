"""Brute-force protection of the promo redeem endpoint (ADR 0018 section 4).

Everything lives in Redis under ``rl:promo:`` and fails closed: when Redis cannot be reached the
caller gets 503 ``promo_unavailable`` and no lookup happens. Keys hold hashes of ids and
addresses, never the values and never a code.

Order of ``check``: per-account attempt bucket, per-address bucket, daily lockout, breaker. A
failure is counted (``INCR`` then ``EXPIRE``, atomically) before the response is sent. The
breaker is an alert: more than ``PROMO_BREAKER_THRESHOLD`` failures over all accounts in the
window log ``promo_breaker_tripped`` and, for the block period, refuse callers that already
failed today; nobody else is blocked.
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


def _unavailable() -> AppError:
    return AppError(503, "promo_unavailable", "Promo codes are temporarily unavailable")


class PromoGuard:
    def __init__(self, redis: Redis, settings: Settings) -> None:
        self._redis = redis
        self._settings = settings

    async def check(self, user_id: uuid.UUID, ip: str) -> None:
        """Raise 429 ``rate_limited`` / ``promo_locked`` or 503 ``promo_unavailable``."""
        s = self._settings
        try:
            await self._attempt("user", str(user_id), s.promo_rate_limit_per_user)
            await self._attempt("ip", ip, s.promo_rate_limit_per_ip)
            failures, fail_ttl, blocked = await self._failures_today(user_id)
        except (RedisError, OSError):
            _log.warning("promo_guard_unavailable")
            raise _unavailable() from None
        if failures >= s.promo_max_failed_per_day:
            retry_after = fail_ttl if fail_ttl > 0 else s.promo_lockout_window_seconds
            raise AppError(
                429,
                "promo_locked",
                "Too many wrong codes, try again later",
                headers={"Retry-After": str(retry_after)},
            )
        if blocked and failures >= 1:
            raise _unavailable()

    async def record_failure(self, user_id: uuid.UUID) -> None:
        """Count one failed redeem; must run before the failure is answered."""
        s = self._settings
        try:
            async with self._redis.pipeline(transaction=True) as pipe:
                fail_key = bucket_key("fail", str(user_id))
                pipe.incr(fail_key)
                pipe.expire(fail_key, s.promo_lockout_window_seconds, nx=True)
                pipe.incr(GLOBAL_FAILURES_KEY)
                pipe.expire(GLOBAL_FAILURES_KEY, s.promo_breaker_window_seconds, nx=True)
                results = await pipe.execute()
            total = int(results[2])
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
            raise _unavailable() from None

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

    async def _failures_today(self, user_id: uuid.UUID) -> tuple[int, int, bool]:
        key = bucket_key("fail", str(user_id))
        async with self._redis.pipeline(transaction=False) as pipe:
            pipe.get(key)
            pipe.ttl(key)
            pipe.exists(BREAKER_BLOCK_KEY)
            count, ttl, blocked = await pipe.execute()
        return int(count or 0), int(ttl), bool(blocked)
