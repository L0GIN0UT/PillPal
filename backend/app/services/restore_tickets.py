"""Restore tickets: the bearer secret that lets a pending account start its restore.

``POST /v1/auth/login`` with the right password for a pending account answers
``account_pending_deletion`` with a ticket. The ticket alone restores nothing: the restore
also needs the one-time code mailed at the same moment (ADR 0010 §2). It is 256 bits,
stored in Redis only as ``sha256`` under the ``rt:`` keyspace, expires after
``ACCOUNT_RESTORE_TICKET_TTL_SECONDS`` and is spent by a successful restore. It is bound to
the deletion cycle (``users.deletion_requested_at``): after a restore and a new request, a
ticket of the earlier cycle is dead.

Unlike the rate limiter this fails *closed*: without Redis no ticket can be issued or
checked, so the user is asked to try again rather than given a weaker flow.
"""

from __future__ import annotations

import hashlib
import secrets
import uuid
from datetime import UTC, datetime

from redis.asyncio import Redis
from redis.exceptions import RedisError

from app.errors import AppError
from app.observability import get_logger

_log = get_logger("pillpal.restore_tickets")

KEY_PREFIX = "rt:"
TICKET_BYTES = 32  # 256 bits


def _key(ticket: str) -> str:
    return KEY_PREFIX + hashlib.sha256(ticket.encode()).hexdigest()


def cycle_of(deletion_requested_at: datetime) -> str:
    """The deletion cycle a ticket is bound to (the request instant, UTC, microseconds)."""
    return deletion_requested_at.astimezone(UTC).isoformat()


def unavailable() -> AppError:
    return AppError(503, "retry_later", "Temporarily unavailable, retry")


class RestoreTickets:
    def __init__(self, redis: Redis, ttl_seconds: int) -> None:
        self._redis = redis
        self._ttl = ttl_seconds

    async def issue(self, user_id: uuid.UUID, cycle: str) -> str:
        ticket = secrets.token_urlsafe(TICKET_BYTES)
        try:
            await self._redis.set(_key(ticket), f"{user_id}|{cycle}", ex=self._ttl)
        except (RedisError, OSError):
            _log.error("restore_ticket_store_unavailable")
            raise unavailable() from None
        return ticket

    async def owner(self, ticket: str) -> tuple[uuid.UUID, str] | None:
        """``(account, deletion cycle)`` of a live ticket (``None``: unknown, spent, expired)."""
        try:
            value = await self._redis.get(_key(ticket))
        except (RedisError, OSError):
            _log.error("restore_ticket_store_unavailable")
            raise unavailable() from None
        if value is None:
            return None
        text = value.decode() if isinstance(value, bytes) else str(value)
        user_id, _, cycle = text.partition("|")
        return uuid.UUID(user_id), cycle

    async def spend(self, ticket: str) -> None:
        try:
            await self._redis.delete(_key(ticket))
        except (RedisError, OSError):
            # The code is already consumed, so the ticket cannot restore anything again;
            # it expires on its own.
            _log.warning("restore_ticket_spend_failed")
