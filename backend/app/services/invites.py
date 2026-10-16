"""Invites: create, list, revoke, preview and accept (ADR 0005 §3-§4, ADR 0009 §4).

The token is a 256-bit bearer capability: it is shown once (in the URL fragment),
only ``sha256(token)`` is stored, and it never appears in a log or an exception.
Accepting locks the invite row, so two accounts racing for one link produce one
grant. A consumed invite never creates a grant again: a replay by the same account
returns the grant only while it still exists, so a revoked relative cannot come back
with the old link.
"""

from __future__ import annotations

import hashlib
import secrets
import uuid
from datetime import datetime, timedelta

from sqlalchemy import ColumnElement, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased

from app.config import Settings
from app.db.models import Profile
from app.db.relatives import Invite, ProfileGrant
from app.errors import AppError, not_found, validation_failed
from app.observability import get_logger
from app.schemas.relatives import IncomingGrantOut, InviteCreate, InviteCreated, InvitePreview
from app.services import entities as entity_service
from app.services.archives import is_archived, read_only
from app.services.changes import journal_head, lock_journal
from app.services.grants import count_relatives, incoming_out, self_display_names
from app.services.scope_limit import ensure_scope_room, lock_access

_log = get_logger("pillpal.invites")

TOKEN_BYTES = 32  # 256 bits
UNIQUE_VIOLATION = "23505"
CHECK_VIOLATION = "23514"


def invite_invalid() -> AppError:
    return AppError(404, "invite_invalid", "This invite link is not valid")


def invite_expired() -> AppError:
    return AppError(410, "invite_expired", "This invite link has expired")


def invite_used() -> AppError:
    return AppError(409, "invite_used", "This invite link has already been used")


def invite_own_profile() -> AppError:
    return AppError(409, "invite_own_profile", "You cannot accept an invite to your own profile")


def already_linked() -> AppError:
    return AppError(409, "already_linked", "You already have access to this profile")


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


async def enqueue_link_accepted(
    session: AsyncSession, *, grant: ProfileGrant, owner_user_id: uuid.UUID
) -> None:
    """Tell the profile's owner that a relative accepted (``link_accepted`` push).

    Seam for milestone 3.4 (push outbox, ADR 0008): the push is enqueued in the
    accepting transaction. Until then there is nothing to enqueue, and the owner sees
    the new link in ``GET /v1/grants`` (the "new relative" banner).
    """


# --- create, list, revoke ---------------------------------------------------------------------


def _is_active(now: datetime) -> tuple[ColumnElement[bool], ...]:
    return (Invite.consumed_at.is_(None), Invite.revoked_at.is_(None), Invite.expires_at > now)


async def _active_count(session: AsyncSession, profile_id: uuid.UUID, now: datetime) -> int:
    count = await session.scalar(
        select(func.count())
        .select_from(Invite)
        .where(Invite.profile_id == profile_id, *_is_active(now))
    )
    return int(count or 0)


def _build_invite(
    settings: Settings,
    now: datetime,
    owner_id: uuid.UUID,
    profile_id: uuid.UUID,
    body: InviteCreate,
) -> tuple[Invite, str]:
    """A new invite and its token (the only moment the token exists server-side)."""
    token = secrets.token_urlsafe(TOKEN_BYTES)
    guardian = body.role == "guardian"
    ttl = settings.guardian_invite_ttl_seconds if guardian else settings.invite_ttl_seconds
    invite = Invite(
        id=body.id,
        profile_id=profile_id,
        created_by_user_id=owner_id,
        role=body.role,
        disclosure_version=body.disclosure_version,
        token_hash=hash_token(token),
        created_at=now,
        expires_at=now + timedelta(seconds=ttl),
    )
    return invite, token


async def create_invite(
    session: AsyncSession,
    settings: Settings,
    now: datetime,
    owner_id: uuid.UUID,
    profile_id: uuid.UUID,
    body: InviteCreate,
) -> InviteCreated:
    """Create an invite on a profile the caller owns; the token is returned only here."""
    # FOR SHARE: a concurrent delete of the profile waits for this transaction.
    profile = await entity_service.load_profile(
        session, owner_id, profile_id, lock="share", owner_only=True
    )
    if profile is None:
        raise not_found()
    if is_archived(profile):
        raise read_only()  # an archive is read-only for everyone, its owner included
    if body.role == "guardian" and profile.kind != "managed":
        raise validation_failed(("body", "role"), "guardian invites need a managed profile")
    if body.disclosure_version not in settings.supported_disclosure_versions:
        raise validation_failed(("body", "disclosure_version"), "unknown disclosure version")
    # A replay of the id is a conflict before anything else: the token cannot be shown twice.
    if await session.get(Invite, body.id) is not None:
        raise entity_service.already_exists()
    # Serialize creators of one profile so concurrent requests cannot exceed the cap.
    await session.execute(
        select(func.pg_advisory_xact_lock(func.hashtextextended(f"invites:{profile_id}", 0)))
    )
    if await _active_count(session, profile_id, now) >= settings.max_active_invites_per_profile:
        raise AppError(409, "too_many_invites", "Too many open invites for this profile")
    invite, token = _build_invite(settings, now, owner_id, profile_id, body)
    await entity_service.insert_new(session, invite)
    await session.commit()
    _log.info("invite_created", invite_id=str(invite.id), profile_id=str(profile_id))
    url = f"{settings.public_link_base_url}/i#{token}"
    return InviteCreated(id=invite.id, role=body.role, expires_at=invite.expires_at, url=url)


async def list_invites(
    session: AsyncSession,
    settings: Settings,
    now: datetime,
    owner_id: uuid.UUID,
    profile_id: uuid.UUID,
) -> list[Invite]:
    if await entity_service.load_profile(session, owner_id, profile_id, owner_only=True) is None:
        raise not_found()
    rows = await session.scalars(
        select(Invite)
        .where(Invite.profile_id == profile_id, *_is_active(now))
        .order_by(Invite.created_at, Invite.id)
        .limit(settings.max_active_invites_per_profile)
    )
    return list(rows)


async def revoke_invite(
    session: AsyncSession,
    now: datetime,
    owner_id: uuid.UUID,
    profile_id: uuid.UUID,
    invite_id: uuid.UUID,
) -> None:
    """Revoke an open invite (idempotent); a consumed one is revoked through its grant."""
    if await entity_service.load_profile(session, owner_id, profile_id, owner_only=True) is None:
        raise not_found()
    invite = await session.scalar(
        select(Invite)
        .where(Invite.id == invite_id, Invite.profile_id == profile_id)
        .with_for_update()
    )
    if invite is None:
        raise not_found()
    if invite.consumed_at is not None:
        raise invite_used()
    if invite.revoked_at is None:
        invite.revoked_at = now
        await session.commit()
        _log.info("invite_revoked", invite_id=str(invite_id), profile_id=str(profile_id))


# --- preview and accept -----------------------------------------------------------------------


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
        stmt = stmt.with_for_update(of=Invite)
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
    inviter_name = await session.scalar(
        select(inviter.display_name).where(
            inviter.owner_user_id == invite.created_by_user_id,
            inviter.kind == "self",
            inviter.deleted_at.is_(None),
        )
    )
    return InvitePreview.model_validate(
        {
            "inviter_display_name": inviter_name,
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


async def _check_limits(
    session: AsyncSession, settings: Settings, user_id: uuid.UUID, profile: Profile
) -> None:
    # Held until commit: concurrent accepts of one account (scopes) or into one owner's
    # profiles (relatives) are serialized, so neither limit can be overshot.
    await lock_access(session, [user_id, profile.owner_user_id])
    if (
        settings.feature_soft_limits
        and await count_relatives(session, profile.owner_user_id) >= settings.soft_limit_relatives
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
    invite, profile = await _invite_with_profile(session, token, lock=True)
    if invite.consumed_at is not None:
        return await _replay(session, invite, profile, user_id)
    if invite.expires_at <= now:
        raise invite_expired()
    if profile.owner_user_id == user_id:
        raise invite_own_profile()
    if await _existing_grant(session, profile.id, user_id) is not None:
        raise already_linked()  # the invite stays open for somebody else
    # Every writer of the owner's journal holds this lock until commit, so the head read
    # below is exact: whatever is journaled later gets a higher seq (ADR 0006 §4). The
    # journal lock comes before the access locks, like in every other writer.
    await lock_journal(session, [profile.owner_user_id])
    await _check_limits(session, settings, user_id, profile)
    grant = await _insert_grant(session, invite, profile, user_id)
    invite.consumed_at = now
    invite.consumed_by_user_id = user_id
    await enqueue_link_accepted(session, grant=grant, owner_user_id=profile.owner_user_id)
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
