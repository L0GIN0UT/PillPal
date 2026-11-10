"""Entitlements of one account (ADR 0018). Always scoped by the account: never inherited."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.db.entitlements import Entitlement
from app.domain.entitlements import Effective, effective, is_active
from app.domain.payments import app_account_token
from app.schemas.entitlements import EntitlementOut, EntitlementsOut


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


def account_token_for(settings: Settings, user_id: uuid.UUID) -> uuid.UUID | None:
    """The account's StoreKit ``appAccountToken``; ``None`` unless payments are on and keyed.

    A derived identifier the app discloses to the store at purchase (docs/spec/export.md), so it
    is not handed out while payments are off.
    """
    key = settings.payments_key_bytes()
    if not settings.feature_payments or key is None:
        return None
    return app_account_token(key, user_id)


async def entitlements_out(
    session: AsyncSession, settings: Settings, user_id: uuid.UUID, now: datetime
) -> EntitlementsOut:
    """The answer of ``GET /v1/me/entitlements``, of the promo redeem and of a purchase."""
    state, active = await current_entitlements(session, user_id, now)
    return EntitlementsOut(
        app_account_token=account_token_for(settings, user_id),
        ads_removed=state.ads_removed,
        limits_lifted=state.limits_lifted,
        items=[EntitlementOut.model_validate(row) for row in active],
        server_time=now,
    )
