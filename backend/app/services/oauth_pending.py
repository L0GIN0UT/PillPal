"""Finishing the e-mail fallback at ``verify-email`` (ADR 0017 section 5).

A provider that did not verify the address (VK ID, unless proven otherwise) leaves an unverified,
passwordless account and a pending identity in Redis, bound to ``(e-mail, provider, subject)``.
The mailed code proves the mailbox; only then is the identity attached. If the address has become
verified by another path in the meantime, nothing is attached and the "address already has an
account" notice runs instead.
"""

from __future__ import annotations

import uuid
from collections.abc import Awaitable, Callable
from datetime import datetime

from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.identities import AuthIdentity
from app.db.models import User
from app.domain.passwords import has_usable_password
from app.observability import get_logger
from app.services.oauth_state import OAuthState

_log = get_logger("pillpal.oauth")


async def attach_pending_identity(
    session: AsyncSession,
    state: OAuthState,
    user: User,
    *,
    was_verified: bool,
    notify_existing: Callable[[User], Awaitable[None]],
    notify_not_linked: Callable[[User], Awaitable[None]],
    pending_token: str | None,
    now: datetime,
) -> None:
    """Attach the pending identity of ``user`` after a valid code; a no-op for password accounts.

    Redis down raises 503 when it is consulted (the caller has not committed, so the code stays
    usable). It is consulted for a passwordless account and for an address that was verified
    before this code; an ordinary password account never touches Redis here.
    """
    if has_usable_password(user.password_hash) and not was_verified:
        return
    passwordless = not has_usable_password(user.password_hash)
    pending = await state.take_pending(user.id)
    if pending is None or pending.email != user.email.lower():
        if passwordless:
            await notify_not_linked(user)  # a verified account with no way to sign in yet
        return
    if was_verified:
        await notify_existing(user)
        return
    if not pending.matches_token(pending_token):
        # The code proves the mailbox, not who started the sign-up: without the token nothing is
        # linked, the entry is gone and the owner of the address is told.
        await notify_not_linked(user)
        return
    try:
        # A savepoint: a taken identity must not undo the verification itself.
        async with session.begin_nested():
            session.add(
                AuthIdentity(
                    id=uuid.uuid4(),
                    user_id=user.id,
                    provider=pending.provider,
                    subject=pending.subject,
                    email_at_link=None,
                    created_at=now,
                    last_used_at=now,
                )
            )
    except IntegrityError:
        _log.info("oauth_pending_identity_taken", provider=pending.provider)
