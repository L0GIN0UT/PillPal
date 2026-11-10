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
        self._ip_multiplier = settings.rate_limit_ip_multiplier

    async def check(
        self,
        scope: str,
        ip: str,
        subject: str | None,
        *,
        per_account: bool = False,
        limit: int | None = None,
        window: int | None = None,
        fail_closed: bool = False,
    ) -> None:
        """Count one attempt; raise 429 when a bucket is over its limit.

        Buckets: per IP, per (IP, subject) and - with ``per_account`` - per
        subject across all IPs, so rotating source addresses does not multiply
        the attempts against one account. ``limit`` and ``window`` replace the auth defaults
        (the per-IP bucket stays ``multiplier`` times wider). ``fail_closed``: with Redis down the
        request is refused (503), for scopes that guard a password check or a secret.
        """
        per_bucket = limit if limit is not None else self._limit
        ip_limit = per_bucket * self._ip_multiplier if limit is not None else self._ip_limit
        window = window if window is not None else self._window
        buckets = [(_bucket(scope, "ip", ip), ip_limit)]
        if subject is not None:
            buckets.append((_bucket(scope, "subject", ip, subject), per_bucket))
            if per_account and subject:
                buckets.append((_bucket(scope, "account", subject), per_bucket))
        try:
            async with self._redis.pipeline(transaction=False) as pipe:
                for key, _ in buckets:
                    pipe.incr(key)
                    pipe.expire(key, window, nx=True)
                    pipe.ttl(key)
                results = await pipe.execute()
        except (RedisError, OSError):
            _log.warning("rate_limiter_unavailable", scope=scope)
            if fail_closed:
                raise AppError(503, "rate_limit_unavailable", "Try again later") from None
            return
        for i, (_, bucket_limit) in enumerate(buckets):
            count, ttl = int(results[i * 3]), int(results[i * 3 + 2])
            if count > bucket_limit:
                retry_after = ttl if ttl > 0 else window
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


def limit_by_email(scope: str, *, optional: bool = False) -> Callable[[Request], Awaitable[None]]:
    """Dependency: limit per IP, per (IP, e-mail from the JSON body) and per e-mail.

    ``optional``: a body without an e-mail is not counted here (the route has another path).
    """

    async def dependency(request: Request) -> None:
        limiter: RateLimiter = request.app.state.rate_limiter
        email = await _email_from_raw_body(request)
        if optional and email is None:
            return
        await limiter.check(scope, client_ip(request), email or "", per_account=True)

    return dependency


def _body_field(data: object, field: str) -> str | None:
    value = data.get(field) if isinstance(data, dict) else None
    return value[:256] if isinstance(value, str) else None


def limit_by_body_field(scope: str, field: str) -> Callable[[Request], Awaitable[None]]:
    """Dependency: limit per IP, per (IP, value of ``field`` in the JSON body) and per value.

    For single-use secrets (a sign-up ticket): hammering one is counted across source
    addresses. Read before body validation, so malformed requests count too.
    """

    async def dependency(request: Request) -> None:
        limiter: RateLimiter = request.app.state.rate_limiter
        try:
            data = json.loads(await request.body())
        except ValueError:
            data = None
        await limiter.check(
            scope, client_ip(request), _body_field(data, field) or "", per_account=True
        )

    return dependency


def limit_by_ip(scope: str) -> Callable[[Request], Awaitable[None]]:
    async def dependency(request: Request) -> None:
        limiter: RateLimiter = request.app.state.rate_limiter
        await limiter.check(scope, client_ip(request), None)

    return dependency
