"""The provider refresh token of an identity: store it sealed, revoke it (ADR 0017 section 9).

Only Apple has one. The token is sealed with the data-encryption keyring (ADR 0016 section 9):
purpose ``pillpal-oauth-refresh/v1``, row id = the identity id. Revocation is best effort and never
raises: a failure is logged by exception type and nothing else, because a token, a code or a
subject must not reach a log.

* Inline callers (unlink, a token that was discarded) revoke once with a short timeout
  (``OAUTH_REVOKE_INLINE_TIMEOUT_SECONDS``).
* Deletion never waits on Apple: :func:`revoke_pending_tokens` runs in the worker sweep (every few
  minutes, the backoff) over identities of accounts that are pending deletion, clears the column
  only after Apple accepted, and runs once more for the account right before its hard erase.
  Each run pages through *every* pending row (keyset on ``created_at, id``), so rows that always
  fail cannot starve the ones behind them; a blob that cannot be opened (a retired key, damage)
  can never be revoked, so it is dropped instead of retried for ever.
"""

from __future__ import annotations

import time
import uuid
from collections.abc import Callable
from datetime import datetime
from enum import Enum

from sqlalchemy import select, tuple_, update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.db.identities import AuthIdentity
from app.db.models import User
from app.oauth.apple_tokens import AppleTokenClient, AppleTokenError
from app.observability import get_logger
from app.services.data_encryption import DataKeyring, DecryptionError, UnknownKeyError

REFRESH_PURPOSE = "pillpal-oauth-refresh/v1"
APPLE = "apple"
REVOKE_ATTEMPTS = 2  # one try and one retry
# A sweep stops after this many failed revokes in a row (an outage) or this much wall clock, far
# below the worker job timeout; the next cron run (5 minutes) continues.
DEFAULT_MAX_CONSECUTIVE_FAILURES = 5
DEFAULT_BUDGET_SECONDS = 120.0

_log = get_logger("pillpal.oauth")


class RevokeOutcome(Enum):
    REVOKED = "revoked"  # the provider accepted: the stored token can go
    FAILED = "failed"  # worth another try later (outage, not configured here)
    UNUSABLE = "unusable"  # can never succeed: the blob cannot be opened or has no revoke


class ProviderTokens:
    def __init__(
        self,
        apple: AppleTokenClient | None,
        keyring: DataKeyring | None,
        *,
        inline_timeout_seconds: float = 3.0,
    ) -> None:
        self._apple = apple
        self._keyring = keyring
        self._inline_timeout = inline_timeout_seconds

    async def exchange_and_seal(
        self,
        provider: str,
        code: str | None,
        subject: str,
        identity_id: uuid.UUID,
        now: datetime,
    ) -> bytes | None:
        """The sealed refresh token for ``code``, or ``None``: sign-in never depends on it."""
        if provider != APPLE or not code or self._apple is None or self._keyring is None:
            return None
        try:
            exchange = await self._apple.exchange_code(code, now)
        except AppleTokenError as exc:
            _log.warning("apple_exchange_failed", error_type=type(exc).__name__)
            return None
        if exchange.subject != subject:
            _log.warning("apple_exchange_subject_mismatch")
            return None
        return self._keyring.encrypt(REFRESH_PURPOSE, identity_id, exchange.refresh_token.encode())

    async def revoke(
        self,
        provider: str,
        identity_id: uuid.UUID,
        sealed: bytes | None,
        now: datetime,
        *,
        inline: bool = False,
    ) -> bool:
        """Ask Apple to end the token; ``True`` when it did. Never raises."""
        outcome = await self.revoke_outcome(provider, identity_id, sealed, now, inline=inline)
        return outcome is RevokeOutcome.REVOKED

    async def revoke_outcome(
        self,
        provider: str,
        identity_id: uuid.UUID,
        sealed: bytes | None,
        now: datetime,
        *,
        inline: bool = False,
    ) -> RevokeOutcome:
        """One revoke attempt and what it means for the stored column. Never raises.

        ``inline``: a request is waiting, so one short try instead of a try and a retry.
        """
        if sealed is None:
            return RevokeOutcome.UNUSABLE
        if provider != APPLE:
            return RevokeOutcome.UNUSABLE  # only Apple has a token to revoke
        if self._apple is None or self._keyring is None:
            return RevokeOutcome.FAILED  # not configured in this process; another one may be
        try:
            token = self._keyring.decrypt(REFRESH_PURPOSE, identity_id, sealed).decode()
        except UnknownKeyError:
            # A retired key still in use is a configuration problem: keep the token, it opens
            # again when the key is back.
            _log.warning("apple_revoke_key_missing")
            return RevokeOutcome.FAILED
        except (DecryptionError, UnicodeDecodeError) as exc:
            _log.warning("apple_revoke_unusable", error_type=type(exc).__name__)
            return RevokeOutcome.UNUSABLE
        timeout = self._inline_timeout if inline else None
        error_type = ""
        for _ in range(1 if inline else REVOKE_ATTEMPTS):
            try:
                await self._apple.revoke(token, now, timeout_seconds=timeout)
            except AppleTokenError as exc:
                error_type = type(exc).__name__
                continue
            return RevokeOutcome.REVOKED
        _log.warning("apple_revoke_failed", error_type=error_type)
        return RevokeOutcome.FAILED


async def revoke_pending_tokens(
    maker: async_sessionmaker[AsyncSession],
    tokens: ProviderTokens,
    now: datetime,
    *,
    limit: int,
    user_id: uuid.UUID | None = None,
    max_consecutive_failures: int = DEFAULT_MAX_CONSECUTIVE_FAILURES,
    budget_seconds: float = DEFAULT_BUDGET_SECONDS,
    monotonic: Callable[[], float] = time.monotonic,
) -> int:
    """Revoke the stored provider tokens of accounts pending deletion; returns how many cleared.

    ``limit`` is the page size: pages follow each other until no pending row is left, so a row
    that fails every time never hides the rows after it. The column is cleared when Apple
    accepted the revoke, or when the blob can never be revoked (:attr:`RevokeOutcome.UNUSABLE`),
    and only if it still holds the value that was read; a failure leaves it for the next sweep
    (or the pre-erase attempt). No database connection is held while Apple is asked.

    The run stops early (the next cron run continues) after ``max_consecutive_failures`` failed
    revokes in a row (an outage: asking on only burns time) or when ``budget_seconds`` of wall
    clock are spent, which keeps it well under the worker job timeout.
    """
    cleared = dropped = failures = 0
    deadline = monotonic() + budget_seconds
    after: tuple[datetime, uuid.UUID] | None = None
    while True:
        page = await _pending_page(maker, limit, user_id, after)
        for _created_at, identity_id, provider, sealed in page:
            if failures >= max_consecutive_failures or monotonic() >= deadline:
                _log.warning("revoke_sweep_stopped", cleared=cleared, dropped=dropped)
                return cleared
            outcome = await tokens.revoke_outcome(provider, identity_id, sealed, now)
            if outcome is RevokeOutcome.FAILED:
                failures += 1
                continue
            failures = 0
            if outcome is RevokeOutcome.UNUSABLE:
                dropped += 1
                _log.warning("provider_token_dropped", identity_id=str(identity_id))
            await _clear(maker, identity_id, sealed)
            cleared += 1
        if len(page) < limit:
            if dropped:
                _log.warning("revoke_sweep_dropped", count=dropped)
            return cleared
        after = (page[-1][0], page[-1][1])


async def _pending_page(
    maker: async_sessionmaker[AsyncSession],
    limit: int,
    user_id: uuid.UUID | None,
    after: tuple[datetime, uuid.UUID] | None,
) -> list[tuple[datetime, uuid.UUID, str, bytes]]:
    query = (
        select(
            AuthIdentity.created_at,
            AuthIdentity.id,
            AuthIdentity.provider,
            AuthIdentity.provider_refresh_token_enc,
        )
        .join(User, User.id == AuthIdentity.user_id)
        .where(
            User.deletion_requested_at.is_not(None),
            AuthIdentity.provider_refresh_token_enc.is_not(None),
        )
        .order_by(AuthIdentity.created_at, AuthIdentity.id)
        .limit(limit)
    )
    if user_id is not None:
        query = query.where(AuthIdentity.user_id == user_id)
    if after is not None:
        query = query.where(tuple_(AuthIdentity.created_at, AuthIdentity.id) > tuple_(*after))
    async with maker() as session:
        rows = (await session.execute(query)).all()
    return [(c, i, p, bytes(s)) for c, i, p, s in rows if s is not None]


async def _clear(
    maker: async_sessionmaker[AsyncSession], identity_id: uuid.UUID, sealed: bytes
) -> None:
    async with maker() as session:
        await session.execute(
            update(AuthIdentity)
            .where(
                AuthIdentity.id == identity_id,
                AuthIdentity.provider_refresh_token_enc == sealed,
            )
            .values(provider_refresh_token_enc=None)
            .execution_options(synchronize_session=False)
        )
        await session.commit()
