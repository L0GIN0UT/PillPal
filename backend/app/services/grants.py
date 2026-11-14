"""Grants: listing, changing and revoking links between accounts (ADR 0005 §3).

A grant is created only by accepting an invite (``app.services.invite_accept``). The
owner of the profile may change its ``role``; the grantee may change
``notify_missed``; either may delete it (revoke or leave: a hard DELETE, no link
history is kept; the parties' private notes about each other go once nothing links them,
ADR 0020). A caller who is neither gets 404, like for a missing grant.
"""

from __future__ import annotations

import uuid
from collections.abc import Collection
from datetime import datetime
from typing import Literal

from sqlalchemy import and_, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.db.models import Profile
from app.db.relatives import ProfileGrant
from app.errors import AppError, not_found, validation_failed
from app.schemas.relatives import (
    GrantList,
    GrantPatch,
    IncomingGrantOut,
    OutgoingGrantOut,
)
from app.services.access import grant_is_active
from app.services.archives import is_archived, read_only
from app.services.relative_notes import notes_about, prune_notes

Party = Literal["owner", "grantee"]


async def self_profiles(
    session: AsyncSession, user_ids: Collection[uuid.UUID]
) -> dict[uuid.UUID, tuple[uuid.UUID, str | None]]:
    """Id and display name of each account's live self profile (what a relative knows them by)."""
    if not user_ids:
        return {}
    rows = await session.execute(
        select(Profile.owner_user_id, Profile.id, Profile.display_name).where(
            Profile.owner_user_id.in_(user_ids),
            Profile.kind == "self",
            Profile.deleted_at.is_(None),
        )
    )
    return {user_id: (profile_id, name) for user_id, profile_id, name in rows}


async def self_display_names(
    session: AsyncSession, user_ids: Collection[uuid.UUID]
) -> dict[uuid.UUID, str]:
    """Display name of each account's self profile (what a relative recognises them by)."""
    profiles = await self_profiles(session, user_ids)
    return {user_id: name for user_id, (_, name) in profiles.items() if name is not None}


def incoming_out(
    grant: ProfileGrant, profile: Profile, owner_display_name: str | None
) -> IncomingGrantOut:
    return IncomingGrantOut.model_validate(
        {
            "id": grant.id,
            "profile_id": profile.id,
            "profile_display_name": profile.display_name,
            "profile_kind": profile.kind,
            "owner_display_name": owner_display_name,
            "role": grant.role,
            "notify_missed": grant.notify_missed,
            "created_at": grant.created_at,
        }
    )


def outgoing_out(
    grant: ProfileGrant,
    profile: Profile,
    grantee: tuple[uuid.UUID, str | None] | None,
    active: bool,
) -> OutgoingGrantOut:
    """``grantee``: id and name of the grantee's self profile, if it is live."""
    return OutgoingGrantOut.model_validate(
        {
            "id": grant.id,
            "profile_id": profile.id,
            "profile_display_name": profile.display_name,
            "profile_kind": profile.kind,
            "grantee_display_name": grantee[1] if grantee else None,
            "grantee_profile_id": grantee[0] if grantee else None,
            "role": grant.role,
            "active": active,
            "disclosure_version": grant.disclosure_version,
            "created_at": grant.created_at,
        }
    )


async def list_grants(session: AsyncSession, settings: Settings, user_id: uuid.UUID) -> GrantList:
    limit = settings.grants_list_limit
    outgoing_rows = (
        await session.execute(
            select(ProfileGrant, Profile, grant_is_active().label("active"))
            .join(Profile, Profile.id == ProfileGrant.profile_id)
            .where(Profile.owner_user_id == user_id, Profile.deleted_at.is_(None))
            .order_by(ProfileGrant.created_at, ProfileGrant.id)
            .limit(limit)
        )
    ).all()
    incoming_rows = (
        await session.execute(
            select(ProfileGrant, Profile)
            .join(Profile, Profile.id == ProfileGrant.profile_id)
            .where(
                ProfileGrant.grantee_user_id == user_id,
                Profile.deleted_at.is_(None),
                grant_is_active(),
            )
            .order_by(ProfileGrant.created_at, ProfileGrant.id)
            .limit(limit)
        )
    ).all()
    people = await self_profiles(
        session,
        {g.grantee_user_id for g, _, _ in outgoing_rows}
        | {p.owner_user_id for _, p in incoming_rows},
    )
    outgoing = [
        outgoing_out(g, p, people.get(g.grantee_user_id), active) for g, p, active in outgoing_rows
    ]
    incoming = [
        incoming_out(g, p, (people.get(p.owner_user_id) or (None, None))[1])
        for g, p in incoming_rows
    ]
    # Only notes about the subjects listed here: the relationship is what makes a note visible.
    subjects = {o.grantee_profile_id for o in outgoing if o.grantee_profile_id is not None}
    notes = await notes_about(session, user_id, subjects | {i.profile_id for i in incoming})
    return GrantList(outgoing=outgoing, incoming=incoming, notes=notes)


async def _load_for_party(
    session: AsyncSession, user_id: uuid.UUID, grant_id: uuid.UUID
) -> tuple[ProfileGrant, Profile, Party]:
    """The locked grant and its profile; 404 unless the caller is its owner or grantee."""
    row = (
        await session.execute(
            select(ProfileGrant, Profile)
            .join(Profile, Profile.id == ProfileGrant.profile_id)
            .where(
                ProfileGrant.id == grant_id,
                or_(Profile.owner_user_id == user_id, ProfileGrant.grantee_user_id == user_id),
            )
            .with_for_update(of=ProfileGrant)
        )
    ).one_or_none()
    if row is None:
        raise not_found()
    grant, profile = row
    return grant, profile, "owner" if profile.owner_user_id == user_id else "grantee"


async def _grant_is_active(session: AsyncSession, grant_id: uuid.UUID) -> bool:
    active = await session.scalar(
        select(grant_is_active())
        .select_from(ProfileGrant)
        .join(Profile, Profile.id == ProfileGrant.profile_id)
        .where(ProfileGrant.id == grant_id)
    )
    return bool(active)


async def patch_grant(
    session: AsyncSession,
    settings: Settings,
    now: datetime,
    user_id: uuid.UUID,
    grant_id: uuid.UUID,
    body: GrantPatch,
) -> IncomingGrantOut | OutgoingGrantOut:
    grant, profile, party = await _load_for_party(session, user_id, grant_id)
    if profile.deleted_at is not None:
        raise not_found()
    if party == "owner":
        if is_archived(profile):
            raise read_only()  # frozen for the owner; the grantee's own choice stays free
        if body.role is None:
            raise validation_failed(("body", "notify_missed"), "only the grantee can change it")
        if body.role == "guardian":
            raise AppError(
                409,
                "guardian_requires_invite",
                "Guardian access is only given by a guardian invite",
            )
        if body.disclosure_version not in settings.supported_disclosure_versions:
            raise validation_failed(("body", "disclosure_version"), "unknown disclosure version")
        grant.role = body.role
        grant.disclosure_version = body.disclosure_version
    else:
        if not await _grant_is_active(session, grant.id):
            raise not_found()  # a paused or inactive grant looks missing (no inference leak)
        if body.notify_missed is None:
            raise validation_failed(("body", "role"), "only the owner can change it")
        grant.notify_missed = body.notify_missed
    grant.updated_at = now
    await session.flush()
    people = await self_profiles(session, {grant.grantee_user_id, profile.owner_user_id})
    result: IncomingGrantOut | OutgoingGrantOut
    if party == "owner":
        active = await _grant_is_active(session, grant.id)
        result = outgoing_out(grant, profile, people.get(grant.grantee_user_id), active)
    else:
        owner = people.get(profile.owner_user_id)
        result = incoming_out(grant, profile, owner[1] if owner else None)
    await session.commit()
    return result


async def delete_grant(session: AsyncSession, user_id: uuid.UUID, grant_id: uuid.UUID) -> None:
    grant, profile, party = await _load_for_party(session, user_id, grant_id)
    if party == "owner" and is_archived(profile):
        raise read_only()  # revoking is a write; the grantee may always leave
    await session.delete(grant)
    await session.flush()
    # Notes of the two parties about each other go with their last relationship (ADR 0020).
    await prune_notes(session, {grant.grantee_user_id, profile.owner_user_id})
    await session.commit()


async def count_relatives(session: AsyncSession, owner_id: uuid.UUID) -> int:
    """Grants on the owner's live profiles whose parties are not pending deletion (the soft limit
    counts these), paused or not: a pause must not make room for more relatives."""
    count = await session.scalar(
        select(func.count())
        .select_from(ProfileGrant)
        .join(
            Profile,
            and_(Profile.id == ProfileGrant.profile_id, Profile.deleted_at.is_(None)),
        )
        .where(Profile.owner_user_id == owner_id, grant_is_active(include_paused=True))
    )
    return int(count or 0)
