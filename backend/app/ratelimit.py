"""Fixed-window rate limiting in Redis for authentication endpoints.

Fails open: if Redis is unavailable the request is allowed and a warning is
logged. Authentication itself (Argon2, attempt-limited codes) stays the
primary defence; the limiter only blunts brute force and enumeration.
"""

from __future__ import annotations

import hashlib
import json
from collections.abc import Awaitable, Callable

from fastapi import Request
from redis.asyncio import Redis
from redis.exceptions import RedisError

from app.config import Settings
from app.errors import AppError
from app.observability import get_logger

_log = get_logger("pillpal.ratelimit")


def _bucket(*parts: str) -> str:
    # Keys never contain raw e-mail addresses.
    digest = hashlib.sha256("|".join(parts).encode()).hexdigest()[:32]
    return f"rl:{parts[0]}:{digest}"


class RateLimiter:
    def __init__(self, redis: Redis, settings: Settings) -> None:
        self._redis = redis
        self._limit = settings.rate_limit_auth_max_attempts
        self._ip_limit = settings.rate_limit_auth_max_attempts * settings.rate_limit_ip_multiplier
        self._window = settings.rate_limit_auth_window_seconds

    async def check(
        self, scope: str, ip: str, subject: str | None, *, per_account: bool = False
    ) -> None:
        """Count one attempt; raise 429 when a bucket is over its limit.

        Buckets: per IP, per (IP, subject) and - with ``per_account`` - per
        subject across all IPs, so rotating source addresses does not multiply
        the attempts against one account.
        """
        buckets = [(_bucket(scope, "ip", ip), self._ip_limit)]
        if subject is not None:
            buckets.append((_bucket(scope, "subject", ip, subject), self._limit))
            if per_account and subject:
                buckets.append((_bucket(scope, "account", subject), self._limit))
        try:
            async with self._redis.pipeline(transaction=False) as pipe:
                for key, _ in buckets:
                    pipe.incr(key)
                    pipe.expire(key, self._window, nx=True)
                    pipe.ttl(key)
                results = await pipe.execute()
        except (RedisError, OSError):
            _log.warning("rate_limiter_unavailable", scope=scope)
            return
        for i, (_, limit) in enumerate(buckets):
            count, ttl = int(results[i * 3]), int(results[i * 3 + 2])
            if count > limit:
                retry_after = ttl if ttl > 0 else self._window
                _log.info("rate_limited", scope=scope)
                raise AppError(
                    429,
                    "rate_limited",
                    "Too many attempts, try again later",
                    headers={"Retry-After": str(retry_after)},
                )


def client_ip(request: Request) -> str:
    # Behind a reverse proxy run uvicorn with --proxy-headers/--forwarded-allow-ips
    # so request.client reflects the real client address.
    return request.client.host if request.client else "unknown"


async def _email_from_raw_body(request: Request) -> str | None:
    # Read before body validation, so malformed requests are counted too.
    try:
        data = json.loads(await request.body())
    except ValueError:
        return None
    email = data.get("email") if isinstance(data, dict) else None
    return email.strip().lower()[:320] if isinstance(email, str) else None


def limit_by_email(scope: str) -> Callable[[Request], Awaitable[None]]:
    """Dependency: limit per IP, per (IP, e-mail from the JSON body) and per e-mail."""

    async def dependency(request: Request) -> None:
        limiter: RateLimiter = request.app.state.rate_limiter
        email = await _email_from_raw_body(request)
        await limiter.check(scope, client_ip(request), email or "", per_account=True)

    return dependency


def limit_by_ip(scope: str) -> Callable[[Request], Awaitable[None]]:
    async def dependency(request: Request) -> None:
        limiter: RateLimiter = request.app.state.rate_limiter
        await limiter.check(scope, client_ip(request), None)

    return dependency
