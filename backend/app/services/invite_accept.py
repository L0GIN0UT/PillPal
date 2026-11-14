"""Invites: preview and accept (ADR 0005 §3-§4, ADR 0009 §4, ADR 0020 section 3).

Accepting locks the invite row, so two accounts racing for one link produce one
grant. A consumed invite never creates a grant again: a replay by the same account
returns the grant only while it still exists, so a revoked relative cannot come back
with the old link. The preview shows the inviter's masked e-mail only to a holder of
an open token; it is never logged.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased

from app.config import Settings
from app.db.models import Profile, User
from app.db.relatives import Invite, ProfileGrant
from app.domain.email_mask import mask_email
from app.errors import AppError
from app.observability import get_logger
from app.push.base import PushPayload
from app.schemas.relatives import IncomingGrantOut, InvitePreview
from app.services.archives import is_archived
from app.services.changes import journal_head, lock_journal
from app.services.consent_pause import profile_consented
from app.services.entitlements import current_entitlements
from app.services.grants import count_relatives, incoming_out, self_display_names
from app.services.invites import (
    already_linked,
    hash_token,
    invite_expired,
    invite_invalid,
    invite_own_profile,
    invite_used,
)
from app.services.push_outbox import enqueue
from app.services.scope_limit import ensure_scope_room, lock_access

_log = get_logger("pillpal.invites")

UNIQUE_VIOLATION = "23505"
CHECK_VIOLATION = "23514"


async def enqueue_link_accepted(
    session: AsyncSession, *, grant: ProfileGrant, owner_user_id: uuid.UUID, now: datetime
) -> None:
    """Tell the profile's owner that a relative accepted (``link_accepted`` push, ids only).

    Enqueued in the accepting transaction (ADR 0008 §6), so a replay of the accept never
    pushes twice. The owner sees the new link in ``GET /v1/grants`` (the "new relative"
    banner) whether or not push is available to them.
    """
    await enqueue(
        session,
        recipient_user_id=owner_user_id,
        payload=PushPayload(t="link_accepted", p=grant.profile_id, g=grant.id),
        ref=str(grant.id),
        subject_profile_id=grant.profile_id,
        now=now,
    )


async def _invite_with_profile(
    session: AsyncSession, token: str, *, lock: bool
) -> tuple[Invite, Profile]:
    """The invite for a token and its live profile; anything else is ``invite_invalid``."""
    stmt = (
        select(Invite, Profile)
        .join(Profile, Profile.id == Invite.profile_id)
        .where(Invite.token_hash == hash_token(token))
    )
    if lock:
        # The invite row serializes accepters of one link. The profile is not locked here:
        # the grant guard trigger reads it FOR SHARE, so a concurrent delete either commits
        # first (the insert fails, mapped to ``invite_invalid``) or waits for this transaction.
        # populate_existing: the unlocked read may already have loaded these rows (stale).
        stmt = stmt.with_for_update(of=Invite).execution_options(populate_existing=True)
    row = (await session.execute(stmt)).one_or_none()
    if row is None:
        raise invite_invalid()
    invite, profile = row
    if invite.revoked_at is not None or profile.deleted_at is not None or is_archived(profile):
        raise invite_invalid()
    return invite, profile


async def preview_invite(
    session: AsyncSession, now: datetime, user_id: uuid.UUID, token: str
) -> InvitePreview:
    invite, profile = await _invite_with_profile(session, token, lock=False)
    if invite.consumed_at is not None:
        # Only the account that used the link may learn that it was used.
        raise invite_used() if invite.consumed_by_user_id == user_id else invite_invalid()
    if invite.expires_at <= now:
        raise invite_expired()
    if profile.owner_user_id == user_id:
        raise invite_own_profile()
    inviter = aliased(Profile)
    inviter_row = (
        await session.execute(
            select(User.email, inviter.display_name)
            .outerjoin(
                inviter,
                (inviter.owner_user_id == User.id)
                & (inviter.kind == "self")
                & inviter.deleted_at.is_(None),
            )
            .where(User.id == invite.created_by_user_id)
        )
    ).one_or_none()
    inviter_email, inviter_name = inviter_row if inviter_row is not None else (None, None)
    return InvitePreview.model_validate(
        {
            "inviter_display_name": inviter_name,
            "inviter_email_masked": mask_email(inviter_email) if inviter_email else None,
            "profile_display_name": profile.display_name,
            "profile_kind": profile.kind,
            "role": invite.role,
            "expires_at": invite.expires_at,
        }
    )


async def _existing_grant(
    session: AsyncSession, profile_id: uuid.UUID, user_id: uuid.UUID
) -> ProfileGrant | None:
    return await session.scalar(
        select(ProfileGrant).where(
            ProfileGrant.profile_id == profile_id, ProfileGrant.grantee_user_id == user_id
        )
    )


async def _limits_lifted(session: AsyncSession, owner_id: uuid.UUID, now: datetime) -> bool:
    """The owner's own entitlement (a purchase, a promo code or a grant), never a relative's."""
    state, _ = await current_entitlements(session, owner_id, now)
    return state.limits_lifted


async def _check_limits(
    session: AsyncSession, settings: Settings, now: datetime, user_id: uuid.UUID, profile: Profile
) -> None:
    # Held until commit: concurrent accepts of one account (scopes) or into one owner's
    # profiles (relatives) are serialized, so neither limit can be overshot.
    await lock_access(session, [user_id, profile.owner_user_id])
    if (
        settings.feature_soft_limits
        and await count_relatives(session, profile.owner_user_id) >= settings.soft_limit_relatives
        and not await _limits_lifted(session, profile.owner_user_id, now)
    ):
        raise AppError(409, "relatives_limit_reached", "The owner has reached the relatives limit")
    await ensure_scope_room(session, settings, user_id)


async def accept_invite(
    session: AsyncSession,
    settings: Settings,
    now: datetime,
    user_id: uuid.UUID,
    token: str,
) -> tuple[IncomingGrantOut, bool]:
    """Accept an invite: the new grant and ``True``, or - for a replay - the grant and ``False``."""
    # Journal lock before row locks (like every writer, and like ``request_deletion``, which
    # holds the journal lock and then updates this invite): find the owner without locking,
    # take the journal lock, then lock the invite and re-check what may have changed meanwhile.
    _, unlocked = await _invite_with_profile(session, token, lock=False)
    await lock_journal(session, [unlocked.owner_user_id])
    invite, profile = await _invite_with_profile(session, token, lock=True)
    if profile.owner_user_id != unlocked.owner_user_id:
        raise invite_invalid()  # the profile changed hands while we waited
    if invite.consumed_at is not None:
        return await _replay(session, invite, profile, user_id)
    if not await session.scalar(select(profile_consented()).where(Profile.id == profile.id)):
        raise invite_invalid()  # a paused profile takes no new relatives (ADR 0016 section 5)
    if invite.expires_at <= now:
        raise invite_expired()
    if profile.owner_user_id == user_id:
        raise invite_own_profile()
    if await _existing_grant(session, profile.id, user_id) is not None:
        raise already_linked()  # the invite stays open for somebody else
    # The journal lock is held since the top: the head read below is exact, whatever is
    # journaled later gets a higher seq (ADR 0006 §4).
    await _check_limits(session, settings, now, user_id, profile)
    grant = await _insert_grant(session, invite, profile, user_id)
    invite.consumed_at = now
    invite.consumed_by_user_id = user_id
    await enqueue_link_accepted(session, grant=grant, owner_user_id=profile.owner_user_id, now=now)
    out = await _grant_out(session, grant, profile)
    await session.commit()
    _log.info(
        "invite_accepted",
        invite_id=str(invite.id),
        grant_id=str(grant.id),
        profile_id=str(profile.id),
        role=grant.role,
    )
    return out, True


async def _insert_grant(
    session: AsyncSession, invite: Invite, profile: Profile, user_id: uuid.UUID
) -> ProfileGrant:
    grant = ProfileGrant(
        id=uuid.uuid4(),
        profile_id=profile.id,
        grantee_user_id=user_id,
        role=invite.role,
        disclosure_version=invite.disclosure_version,
        invite_id=invite.id,
        granted_seq=await journal_head(session, profile.id),
    )
    try:
        async with session.begin_nested():
            session.add(grant)
    except IntegrityError as exc:
        sqlstate = getattr(exc.orig, "sqlstate", None)
        if sqlstate == UNIQUE_VIOLATION:
            raise already_linked() from None  # two invites of one owner accepted at once
        if sqlstate == CHECK_VIOLATION:
            raise invite_invalid() from None  # the profile was deleted while we were accepting
        raise
    return grant


async def _replay(
    session: AsyncSession, invite: Invite, profile: Profile, user_id: uuid.UUID
) -> tuple[IncomingGrantOut, bool]:
    """A retry by the account that consumed the invite; never re-creates a grant."""
    if invite.consumed_by_user_id != user_id:
        raise invite_used()
    grant = await session.scalar(
        select(ProfileGrant).where(
            ProfileGrant.profile_id == profile.id,
            ProfileGrant.grantee_user_id == user_id,
            ProfileGrant.invite_id == invite.id,
        )
    )
    if grant is None:
        raise invite_used()
    return await _grant_out(session, grant, profile), False


async def _grant_out(
    session: AsyncSession, grant: ProfileGrant, profile: Profile
) -> IncomingGrantOut:
    names = await self_display_names(session, {profile.owner_user_id})
    return incoming_out(grant, profile, names.get(profile.owner_user_id))
