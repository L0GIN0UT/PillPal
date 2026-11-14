"""Invites: create, list, revoke and status (ADR 0005 §3-§4, ADR 0009 §4, ADR 0020).

The token is a 256-bit bearer capability: it is shown once (in the URL fragment),
only ``sha256(token)`` is stored, and it never appears in a log or an exception.
Preview and accept live in ``app.services.invite_accept``.
"""

from __future__ import annotations

import hashlib
import secrets
import uuid
from datetime import datetime, timedelta

from sqlalchemy import ColumnElement, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.db.models import Profile
from app.db.relatives import Invite
from app.errors import AppError, not_found, validation_failed
from app.observability import get_logger
from app.schemas.relatives import InviteCreate, InviteCreated, InviteState, InviteStatus
from app.services import entities as entity_service
from app.services.archives import is_archived, read_only

_log = get_logger("pillpal.invites")

TOKEN_BYTES = 32  # 256 bits


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
    return InviteCreated(
        id=invite.id,
        role=body.role,
        created_at=invite.created_at,
        expires_at=invite.expires_at,
        url=url,
    )


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


def _state(invite: Invite, profile: Profile, now: datetime) -> InviteState:
    if invite.consumed_at is not None:
        return "consumed"
    if invite.revoked_at is not None or profile.deleted_at is not None or is_archived(profile):
        return "revoked"  # a gone or frozen profile takes nobody: accept answers invite_invalid
    if invite.expires_at <= now:
        return "expired"
    return "open"


async def invite_status(
    session: AsyncSession, now: datetime, user_id: uuid.UUID, invite_id: uuid.UUID
) -> InviteStatus:
    """The state of an invite for its creator only; anyone else gets 404 (no enumeration).

    The app polls it while the QR code is on screen; who accepted is read from ``GET /v1/grants``.
    """
    row = (
        await session.execute(
            select(Invite, Profile)
            .join(Profile, Profile.id == Invite.profile_id)
            .where(Invite.id == invite_id, Invite.created_by_user_id == user_id)
        )
    ).one_or_none()
    if row is None:
        raise not_found()
    invite, profile = row
    return InviteStatus(
        id=invite.id,
        role=invite.role,
        state=_state(invite, profile, now),
        created_at=invite.created_at,
        expires_at=invite.expires_at,
    )
