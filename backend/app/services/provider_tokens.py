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
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.db.identities import AuthIdentity
from app.db.models import User
from app.oauth.apple_tokens import AppleTokenClient, AppleTokenError
from app.observability import get_logger
from app.services.data_encryption import DataKeyring, DecryptionError

REFRESH_PURPOSE = "pillpal-oauth-refresh/v1"
APPLE = "apple"
REVOKE_ATTEMPTS = 2  # one try and one retry

_log = get_logger("pillpal.oauth")


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
        """Ask Apple to end the token; ``True`` when it did. Never raises.

        ``inline``: a request is waiting, so one short try instead of a try and a retry.
        """
        if provider != APPLE or sealed is None or self._apple is None or self._keyring is None:
            return False
        try:
            token = self._keyring.decrypt(REFRESH_PURPOSE, identity_id, sealed).decode()
        except (DecryptionError, UnicodeDecodeError) as exc:
            _log.warning("apple_revoke_skipped", error_type=type(exc).__name__)
            return False
        timeout = self._inline_timeout if inline else None
        error_type = ""
        for _ in range(1 if inline else REVOKE_ATTEMPTS):
            try:
                await self._apple.revoke(token, now, timeout_seconds=timeout)
            except AppleTokenError as exc:
                error_type = type(exc).__name__
                continue
            return True
        _log.warning("apple_revoke_failed", error_type=error_type)
        return False


async def revoke_pending_tokens(
    maker: async_sessionmaker[AsyncSession],
    tokens: ProviderTokens,
    now: datetime,
    *,
    limit: int,
    user_id: uuid.UUID | None = None,
) -> int:
    """Revoke the stored provider tokens of accounts pending deletion; returns how many cleared.

    The column is cleared only when Apple accepted the revoke, and only if it still holds the
    value that was revoked; a failure leaves it for the next sweep (or the pre-erase attempt).
    No database connection is held while Apple is asked.
    """
    async with maker() as session:
        query = (
            select(AuthIdentity.id, AuthIdentity.provider, AuthIdentity.provider_refresh_token_enc)
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
        rows = (await session.execute(query)).all()
    cleared = 0
    for identity_id, provider, sealed in rows:
        if not await tokens.revoke(provider, identity_id, sealed, now):
            continue
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
        cleared += 1
    return cleared
