"""``GET /v1/me/entitlements``: what the signed-in account has earned (ADR 0018 section 2).

Per account only: relatives, viewers, editors and co-guardians have their own. Works with
``FEATURE_PAYMENTS=false`` (promo codes and admin grants need no store). The app caches the answer,
so it is never cached by an intermediary.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from fastapi import APIRouter, Response
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.deps import CurrentUser, NowDep, SessionDep, SettingsDep
from app.domain.payments import app_account_token
from app.schemas.entitlements import EntitlementOut, EntitlementsOut
from app.services.entitlements import current_entitlements

router = APIRouter(prefix="/v1/me", tags=["me"])


async def entitlements_out(
    session: AsyncSession, settings: Settings, user_id: uuid.UUID, now: datetime
) -> EntitlementsOut:
    """The answer of this endpoint, of the promo redeem and of a purchase: what is in force."""
    state, active = await current_entitlements(session, user_id, now)
    key = settings.payments_key_bytes()
    return EntitlementsOut(
        app_account_token=None if key is None else app_account_token(key, user_id),
        ads_removed=state.ads_removed,
        limits_lifted=state.limits_lifted,
        items=[EntitlementOut.model_validate(row) for row in active],
        server_time=now,
    )


@router.get("/entitlements")
async def get_entitlements(
    user: CurrentUser, session: SessionDep, settings: SettingsDep, now: NowDep, response: Response
) -> EntitlementsOut:
    response.headers["Cache-Control"] = "private, no-store"
    return await entitlements_out(session, settings, user.id, now)
