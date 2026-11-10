"""Entitlements of one account (ADR 0018). Always scoped by the account: never inherited."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.entitlements import Entitlement
from app.domain.entitlements import Effective, effective, is_active


async def entitlement_rows(session: AsyncSession, user_id: uuid.UUID) -> list[Entitlement]:
    result = await session.scalars(
        select(Entitlement)
        .where(Entitlement.user_id == user_id)
        .order_by(Entitlement.granted_at, Entitlement.id)
    )
    return list(result)


async def current_entitlements(
    session: AsyncSession, user_id: uuid.UUID, now: datetime
) -> tuple[Effective, list[Entitlement]]:
    """The effective state and the rows in force at ``now``."""
    rows = await entitlement_rows(session, user_id)
    return effective(rows, now), [row for row in rows if is_active(row, now)]
