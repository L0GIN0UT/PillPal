"""Refresh-token rotation and logout (mixin of :class:`app.services.auth.AuthService`).

A rotated token that comes back within the reuse window from the same device gets the same pair
once; anything else is theft and revokes the whole family. Behaviour is unchanged by the split.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import TYPE_CHECKING

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.sql.elements import ColumnElement

from app.config import Settings
from app.db.models import RefreshToken, User
from app.errors import unauthorized
from app.observability import get_logger
from app.schemas.auth import TokenPair
from app.security import hash_refresh_token
from app.services.auth_errors import invalid_token
from app.services.devices import touch_device
from app.services.push_tokens import delete_device_token, delete_family_tokens
from app.services.refresh_reuse import RefreshReuse
from app.services.users import lock_user

_log = get_logger("pillpal.auth")


def _now() -> datetime:
    return datetime.now(UTC)


class AuthRefresh:
    session: AsyncSession
    settings: Settings
    reuse: RefreshReuse

    if TYPE_CHECKING:

        async def _issue_tokens(
            self, user_id: uuid.UUID, device_id: str | None, family_id: uuid.UUID | None = None
        ) -> TokenPair: ...

        async def _revoke(self, condition: ColumnElement[bool]) -> None: ...

    async def refresh(
        self, token: str, device_id: str | None, now: datetime | None = None
    ) -> TokenPair:
        now = now or _now()
        found = await self.session.scalar(
            select(RefreshToken).where(RefreshToken.token_hash == hash_refresh_token(token))
        )
        if found is None:
            raise invalid_token()
        # The user row first (like every other path), then the token row: ``DELETE /v1/me``
        # locks the user and then revokes the tokens, so the other order could deadlock.
        user = await lock_user(self.session, found.user_id)
        row = await self.session.scalar(
            select(RefreshToken)
            .where(RefreshToken.id == found.id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
        if row is None or user is None:
            raise invalid_token()
        if row.used_at is not None:
            return await self._repeat_of_rotated(row, user, token, device_id, now)
        if row.revoked_at is not None or row.expires_at <= now or user.pending_deletion:
            raise invalid_token()
        row.used_at = now
        device = device_id or row.device_id
        await touch_device(self.session, self.settings, user.id, device_id)
        tokens = await self._issue_tokens(user.id, device, family_id=row.family_id)
        # Before the commit and under the row lock: a repeat waiting for the lock finds it.
        # If the commit fails the repeat sees an unrotated token and never reads the entry.
        await self.reuse.remember(token, device, tokens.model_dump())
        await self.session.commit()
        return tokens

    async def _repeat_of_rotated(
        self, row: RefreshToken, user: User, token: str, device_id: str | None, now: datetime
    ) -> TokenPair:
        """A rotated token came back: the same device within the window gets the same pair,
        anything else is theft and kills the whole family."""
        window = timedelta(seconds=self.settings.refresh_reuse_window_seconds)
        alive = row.revoked_at is None and row.expires_at > now and not user.pending_deletion
        if alive and row.used_at is not None and now - row.used_at <= window:
            pair = await self.reuse.recall(token, device_id)
            if pair is not None and await self._child_is_unspent(row, pair):
                return TokenPair.model_validate(pair)
        await self._revoke(RefreshToken.family_id == row.family_id)
        # A stolen session must not keep receiving alerts about relatives.
        await delete_family_tokens(self.session, row.user_id, row.family_id)
        await self.session.commit()
        _log.warning("refresh_token_reuse_detected", user_id=str(row.user_id))
        raise unauthorized("token_reused", "Refresh token reuse detected; session revoked")

    async def _child_is_unspent(self, row: RefreshToken, pair: dict[str, object]) -> bool:
        """The cached pair's refresh token is still the live head of the family.

        A lost response never saw it; if it was rotated or revoked since, the repeat of the
        old token is not a retry.
        """
        issued = pair.get("refresh_token")
        if not isinstance(issued, str):
            return False
        child = await self.session.scalar(
            select(RefreshToken).where(RefreshToken.token_hash == hash_refresh_token(issued))
        )
        return (
            child is not None
            and child.family_id == row.family_id
            and child.used_at is None
            and child.revoked_at is None
        )

    async def logout(self, token: str) -> None:
        row = await self.session.scalar(
            select(RefreshToken).where(RefreshToken.token_hash == hash_refresh_token(token))
        )
        if row is not None:
            await self._revoke(RefreshToken.family_id == row.family_id)
            if row.device_id is not None:
                # Signed out: this device no longer needs alerts about relatives.
                await delete_device_token(self.session, row.user_id, row.device_id)
            await self.session.commit()
