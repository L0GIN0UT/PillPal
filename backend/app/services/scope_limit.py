"""How many profiles an account may reach: its own, managed ones and granted ones.

``Settings.max_access_scopes_per_user`` bounds what a pull has to list. Both ways
to gain a scope check it: accepting an invite and creating a managed profile.
They are serialized per account by an advisory lock (:func:`lock_access`), so
concurrent attempts cannot overshoot. Lock order everywhere: the owner's journal
lock (``app.services.changes``) first, then the access locks, sorted.
"""

from __future__ import annotations

import uuid
from collections.abc import Collection

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.errors import AppError
from app.services.access import accessible_profiles


async def lock_access(session: AsyncSession, user_ids: Collection[uuid.UUID]) -> None:
    """Hold the access lock of each account until the transaction ends (sorted keys)."""
    for key in sorted({f"access:{user_id}" for user_id in user_ids}):
        await session.execute(select(func.pg_advisory_xact_lock(func.hashtextextended(key, 0))))


async def ensure_scope_room(session: AsyncSession, settings: Settings, user_id: uuid.UUID) -> None:
    """Raise ``too_many_scopes`` when one more profile would exceed the limit (lock held)."""
    scopes = await session.scalar(
        select(func.count()).select_from(accessible_profiles(user_id).subquery())
    )
    if int(scopes or 0) >= settings.max_access_scopes_per_user:
        raise AppError(409, "too_many_scopes", "You have access to too many profiles")
