"""Change the password of a signed-in account with an e-mail code (mixin of ``AuthService``).

Two steps. ``request`` re-authenticates with the current password and mails a code bound to the
asking session (refresh family, ``sid``), never to the access token: the code outlives a 15
minute access token and still works after the token was refreshed within the family. ``confirm``
sets the new password, ends every other session and forgets their push tokens; the session that
asked stays signed in (its access token dies through ``password_changed_at`` and the refresh
token mints the next one).
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import TYPE_CHECKING

from sqlalchemy import select
from sqlalchemy.sql.elements import ColumnElement

from app.db.models import RefreshToken, User
from app.email import EmailPurpose
from app.errors import unauthorized
from app.observability import get_logger
from app.security import PasswordHasher
from app.services.auth_errors import invalid_token
from app.services.auth_mail import AuthMail
from app.services.push_tokens import delete_tokens_outside_family
from app.services.users import lock_user

_log = get_logger("pillpal.auth")
PURPOSE: EmailPurpose = "password_change"


def _now() -> datetime:
    return datetime.now(UTC)


def _scope(session_id: uuid.UUID) -> str:
    return f"{PURPOSE}:{session_id}"


class AuthPasswordChange(AuthMail):
    hasher: PasswordHasher

    if TYPE_CHECKING:

        async def _revoke(self, condition: ColumnElement[bool]) -> None: ...

    async def _family_is_live(self, user_id: uuid.UUID, session_id: uuid.UUID) -> bool:
        """The session is signed in: its head refresh token is neither revoked nor expired."""
        head = await self.session.scalar(
            select(RefreshToken.id)
            .where(
                RefreshToken.user_id == user_id,
                RefreshToken.family_id == session_id,
                RefreshToken.used_at.is_(None),
                RefreshToken.revoked_at.is_(None),
                RefreshToken.expires_at > _now(),
            )
            .limit(1)
        )
        return head is not None

    async def request_password_change(
        self, user: User, session_id: uuid.UUID, current_password: str
    ) -> None:
        """Mail a code for the session. Answers the same when the per-account cap is reached."""
        if not await self._family_is_live(user.id, session_id):
            raise invalid_token()
        # An account without a password is checked against the dummy hash: never a match.
        if not await self.hasher.verify(user.password_hash, current_password):
            raise unauthorized("invalid_password", "Wrong password")
        code = await self._new_code_capped(user, PURPOSE, _scope(session_id))
        await self.session.commit()
        if code is not None:
            await self._send_code(user, PURPOSE, code)

    async def confirm_password_change(
        self, user_id: uuid.UUID, session_id: uuid.UUID, code: str, new_password: str
    ) -> None:
        user = await lock_user(self.session, user_id)
        if user is None or user.pending_deletion:
            raise invalid_token()
        # Under the lock and before the code: a signed-out session spends nothing.
        if not await self._family_is_live(user_id, session_id):
            raise invalid_token()
        await self._consume_code(user_id, PURPOSE, code, _scope(session_id))
        user.password_hash = await self.hasher.hash(new_password)
        # Access tokens issued before this instant stop working (app.deps).
        user.password_changed_at = user.updated_at = _now()
        others = (RefreshToken.user_id == user_id) & (RefreshToken.family_id != session_id)
        await self._revoke(others)
        await delete_tokens_outside_family(self.session, user_id, session_id)
        await self.session.commit()
        _log.info("password_changed", user_id=str(user_id))
        await self._send_notice(user, "password_changed")
