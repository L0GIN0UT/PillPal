"""Who may see a profile, and in which role (ADR 0005 §1, §3).

A role comes from ownership (``owner``: ``profiles.owner_user_id``, for a managed
profile its primary guardian) or from a grant (``guardian``, ``editor``,
``viewer``). Tombstoned profiles have no roles. ``accessible_profiles`` is a
*SQL predicate* meant to be used as a subquery, so authorization stays inside
every query rather than in a Python filter after it.

A grant is *active* only while its grantee is not ``pending_deletion``, and - unless the
profile is an archive - its owner is not either (:func:`grant_is_active`, ADR 0010 §1).
Archived managed profiles (ADR 0005 §5) admit only owner and guardian roles, and their
guardians stay active while the owner is pending: that is how they read the archive and
leave it. Nothing is stored on the grant, so a restore needs no row to change.
"""

from __future__ import annotations

import uuid
from collections.abc import Collection
from datetime import datetime
from typing import cast, get_args

from sqlalchemy import ColumnElement, Select, and_, exists, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import Profile, User
from app.db.relatives import ProfileGrant
from app.domain.privacy import FULL_ACCESS_ROLES, Role, is_full_access

ALL_ROLES: tuple[Role, ...] = get_args(Role)

__all__ = [
    "ALL_ROLES",
    "FULL_ACCESS_ROLES",
    "Role",
    "accessible_profiles",
    "accessible_scopes",
    "grant_is_active",
    "has_full_access",
    "is_full_access",
    "role_for_profile",
    "role_on_profile",
]


def _pending_users() -> Select[uuid.UUID]:
    # Uncorrelated on purpose: a hashed subplan over the (few) accounts in their grace
    # period, with no auto-correlation surprises inside join conditions.
    return select(User.id).where(User.deletion_requested_at.is_not(None))


def grant_is_active() -> ColumnElement[bool]:
    """Whether a joined ``ProfileGrant`` (with its ``Profile``) currently gives access.

    Inactive while the grantee is pending deletion; while the owner is pending, unless the
    profile is already an archive (D1: its guardians keep reading it); and for any role but
    ``guardian`` on an archive (viewers and editors never see one).
    """
    owner_active = or_(
        Profile.archived_at.is_not(None), Profile.owner_user_id.not_in(_pending_users())
    )
    role_allowed = or_(Profile.archived_at.is_(None), ProfileGrant.role == "guardian")
    return and_(ProfileGrant.grantee_user_id.not_in(_pending_users()), owner_active, role_allowed)


def accessible_profiles(
    user_id: uuid.UUID, roles: Collection[Role] = ALL_ROLES
) -> Select[uuid.UUID]:
    """Ids of live profiles on which ``user_id`` holds one of ``roles``.

    One row per profile: (profile, grantee) is unique, so the outer join cannot
    multiply rows, and the owner never holds a grant on their own profile.
    """
    conditions: list[ColumnElement[bool]] = []
    if "owner" in roles:
        conditions.append(Profile.owner_user_id == user_id)
    grant_roles = [role for role in roles if role != "owner"]
    if grant_roles:
        conditions.append(and_(ProfileGrant.role.in_(grant_roles), grant_is_active()))
    return (
        select(Profile.id)
        .outerjoin(
            ProfileGrant,
            and_(ProfileGrant.profile_id == Profile.id, ProfileGrant.grantee_user_id == user_id),
        )
        .where(Profile.deleted_at.is_(None), or_(*conditions))
    )


def accessible_scopes(
    user_id: uuid.UUID,
) -> Select[uuid.UUID, str, uuid.UUID, str, int, datetime | None, datetime | None]:
    """The same profiles as ``accessible_profiles(user_id)``, with what a pull lists about them.

    Columns: profile id, kind, owner id, grant role (``None`` for the owner), the grant's
    ``granted_seq`` (``None`` for the owner), ``archived_at`` and ``archive_purge_after`` of the
    profile. A test keeps the two predicates in step.
    """
    return (
        select(
            Profile.id,
            Profile.kind,
            Profile.owner_user_id,
            ProfileGrant.role,
            ProfileGrant.granted_seq,
            Profile.archived_at,
            Profile.archive_purge_after,
        )
        .outerjoin(
            ProfileGrant,
            and_(
                ProfileGrant.profile_id == Profile.id,
                ProfileGrant.grantee_user_id == user_id,
                grant_is_active(),
            ),
        )
        .where(
            Profile.deleted_at.is_(None),
            or_(Profile.owner_user_id == user_id, ProfileGrant.id.is_not(None)),
        )
        .order_by(Profile.created_at, Profile.id)
    )


def has_full_access(user_id: uuid.UUID) -> ColumnElement[bool]:
    """Predicate over ``Profile``: ``user_id`` owns it or holds an active guardian grant.

    Owners match whether or not the profile is tombstoned (deleting twice is a no-op
    for them); a guardian loses the profile when it is deleted. Editors and viewers
    never match: they read and write only through sync (ADR 0005, ADR 0006).
    """
    # EXISTS, not ``Profile.id IN accessible_profiles(...)``: the subquery would
    # auto-correlate with the caller's own ``profiles`` FROM.
    guardian_grant = exists().where(
        ProfileGrant.profile_id == Profile.id,
        ProfileGrant.grantee_user_id == user_id,
        ProfileGrant.role == "guardian",
        grant_is_active(),
        Profile.deleted_at.is_(None),
    )
    return or_(Profile.owner_user_id == user_id, guardian_grant)


async def role_on_profile(
    session: AsyncSession, user_id: uuid.UUID, profile: Profile
) -> Role | None:
    """The caller's role on an already loaded profile, which may be a tombstone.

    Sync loads a row first and decides afterwards (ADR 0006 §6). The owner keeps
    the ``owner`` role on a tombstone, so replaying a delete stays an idempotent
    success; nobody else has a role on a deleted profile.
    """
    if profile.owner_user_id == user_id:
        return "owner"
    if profile.deleted_at is not None:
        return None
    grant_role = await session.scalar(
        select(ProfileGrant.role)
        .join(Profile, Profile.id == ProfileGrant.profile_id)
        .where(
            ProfileGrant.profile_id == profile.id,
            ProfileGrant.grantee_user_id == user_id,
            grant_is_active(),
        )
    )
    return None if grant_role is None else cast(Role, grant_role)


async def role_for_profile(
    session: AsyncSession, user_id: uuid.UUID, profile_id: uuid.UUID
) -> Role | None:
    """The caller's role on a live profile, or ``None`` (foreign and missing look alike)."""
    row = (
        await session.execute(
            select(Profile.owner_user_id, ProfileGrant.role)
            .outerjoin(
                ProfileGrant,
                and_(
                    ProfileGrant.profile_id == Profile.id,
                    ProfileGrant.grantee_user_id == user_id,
                    grant_is_active(),
                ),
            )
            .where(Profile.id == profile_id, Profile.deleted_at.is_(None))
        )
    ).one_or_none()
    if row is None:
        return None
    owner_id, grant_role = row
    if owner_id == user_id:
        return "owner"
    if grant_role is None:
        return None
    return cast(Role, grant_role)
