"""Restore tickets: the bearer secret that lets a pending account start its restore.

``POST /v1/auth/login`` with the right password for a pending account answers
``account_pending_deletion`` with a ticket. The ticket alone restores nothing: the restore
also needs the one-time code mailed at the same moment (ADR 0010 §2). It is 256 bits,
stored in Redis only as ``sha256`` under the ``rt:`` keyspace, expires after
``ACCOUNT_RESTORE_TICKET_TTL_SECONDS`` and is spent by a successful restore.

Unlike the rate limiter this fails *closed*: without Redis no ticket can be issued or
checked, so the user is asked to try again rather than given a weaker flow.
"""

from __future__ import annotations

import hashlib
import secrets
import uuid

from redis.asyncio import Redis
from redis.exceptions import RedisError

from app.errors import AppError
from app.observability import get_logger

_log = get_logger("pillpal.restore_tickets")

KEY_PREFIX = "rt:"
TICKET_BYTES = 32  # 256 bits


def _key(ticket: str) -> str:
    return KEY_PREFIX + hashlib.sha256(ticket.encode()).hexdigest()


def unavailable() -> AppError:
    return AppError(503, "retry_later", "Temporarily unavailable, retry")


class RestoreTickets:
    def __init__(self, redis: Redis, ttl_seconds: int) -> None:
        self._redis = redis
        self._ttl = ttl_seconds

    async def issue(self, user_id: uuid.UUID) -> str:
        ticket = secrets.token_urlsafe(TICKET_BYTES)
        try:
            await self._redis.set(_key(ticket), str(user_id), ex=self._ttl)
        except (RedisError, OSError):
            _log.error("restore_ticket_store_unavailable")
            raise unavailable() from None
        return ticket

    async def owner(self, ticket: str) -> uuid.UUID | None:
        """The account a live ticket belongs to (``None``: unknown, spent or expired)."""
        try:
            value = await self._redis.get(_key(ticket))
        except (RedisError, OSError):
            _log.error("restore_ticket_store_unavailable")
            raise unavailable() from None
        if value is None:
            return None
        return uuid.UUID(value.decode() if isinstance(value, bytes) else str(value))

    async def spend(self, ticket: str) -> None:
        try:
            await self._redis.delete(_key(ticket))
        except (RedisError, OSError):
            # The code is already consumed, so the ticket cannot restore anything again;
            # it expires on its own.
            _log.warning("restore_ticket_spend_failed")
