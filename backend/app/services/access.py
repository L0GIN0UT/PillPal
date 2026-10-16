"""Who may see a profile, and in which role (ADR 0005 §1, §3).

A role comes from ownership (``owner``: ``profiles.owner_user_id``, for a managed
profile its primary guardian) or from a grant (``guardian``, ``editor``,
``viewer``). Tombstoned profiles have no roles. ``accessible_profiles`` is a
*SQL predicate* meant to be used as a subquery, so authorization stays inside
every query rather than in a Python filter after it.

Not yet part of the predicate (they arrive with milestone 3.3b, which changes
:func:`grant_is_active` and the profile filter in one place): grants of
accounts pending deletion, and archived profiles.
"""

from __future__ import annotations

import uuid
from collections.abc import Collection
from typing import cast, get_args

from sqlalchemy import ColumnElement, Select, and_, or_, select, true
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import Profile
from app.db.relatives import ProfileGrant
from app.domain.privacy import FULL_ACCESS_ROLES, Role, is_full_access

ALL_ROLES: tuple[Role, ...] = get_args(Role)

__all__ = [
    "ALL_ROLES",
    "FULL_ACCESS_ROLES",
    "Role",
    "accessible_profiles",
    "grant_is_active",
    "is_full_access",
    "role_for_profile",
]


def grant_is_active() -> ColumnElement[bool]:
    """Whether a joined ``ProfileGrant`` row currently gives access.

    Seam for milestone 3.3b (ADR 0005 §3): a grant is inactive while its grantee
    or the profile's owner is ``pending_deletion``. Until accounts can be pending,
    every grant is active.
    """
    return true()


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
