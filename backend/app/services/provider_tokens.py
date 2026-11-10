"""The provider refresh token of an identity: store it sealed, revoke it (ADR 0017 section 9).

Only Apple has one. The token is sealed with the data-encryption keyring (ADR 0016 section 9):
purpose ``pillpal-oauth-refresh/v1``, row id = the identity id. Revocation is best effort (one
retry) and never raises: a failure is logged by exception type and nothing else, because a token,
a code or a subject must not reach a log. :func:`revoke_after_deletion` runs after the deletion
request has committed and clears the column.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.identities import AuthIdentity
from app.oauth.apple_tokens import AppleTokenClient, AppleTokenError
from app.observability import get_logger
from app.services.data_encryption import DataKeyring, DecryptionError

REFRESH_PURPOSE = "pillpal-oauth-refresh/v1"
APPLE = "apple"
REVOKE_ATTEMPTS = 2  # one try and one retry

_log = get_logger("pillpal.oauth")


class ProviderTokens:
    def __init__(self, apple: AppleTokenClient | None, keyring: DataKeyring | None) -> None:
        self._apple = apple
        self._keyring = keyring

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
        self, provider: str, identity_id: uuid.UUID, sealed: bytes | None, now: datetime
    ) -> bool:
        """Ask Apple to end the token; ``True`` when it did. Never raises."""
        if provider != APPLE or sealed is None or self._apple is None or self._keyring is None:
            return False
        try:
            token = self._keyring.decrypt(REFRESH_PURPOSE, identity_id, sealed).decode()
        except (DecryptionError, UnicodeDecodeError) as exc:
            _log.warning("apple_revoke_skipped", error_type=type(exc).__name__)
            return False
        error_type = ""
        for _ in range(REVOKE_ATTEMPTS):
            try:
                await self._apple.revoke(token, now)
            except AppleTokenError as exc:
                error_type = type(exc).__name__
                continue
            return True
        _log.warning("apple_revoke_failed", error_type=error_type)
        return False


async def revoke_after_deletion(
    session: AsyncSession, tokens: ProviderTokens, user_id: uuid.UUID, now: datetime
) -> None:
    """Revoke and clear the stored provider tokens of an account whose deletion has committed.

    The column is cleared whether or not Apple answered: the token is a bearer secret and the
    account is erased within the grace period either way.
    """
    rows = (
        await session.execute(
            select(AuthIdentity.id, AuthIdentity.provider, AuthIdentity.provider_refresh_token_enc)
            .where(
                AuthIdentity.user_id == user_id,
                AuthIdentity.provider_refresh_token_enc.is_not(None),
            )
            .order_by(AuthIdentity.created_at, AuthIdentity.id)
        )
    ).all()
    await session.commit()  # end the read transaction while Apple is asked (nothing expires)
    for identity_id, provider, sealed in rows:
        await tokens.revoke(provider, identity_id, sealed, now)
    if rows:
        await session.execute(
            update(AuthIdentity)
            .where(AuthIdentity.id.in_([row[0] for row in rows]))
            .values(provider_refresh_token_enc=None)
            .execution_options(synchronize_session=False)
        )
        await session.commit()
