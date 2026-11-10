"""``GET /v1/me/entitlements``: what the signed-in account has earned (ADR 0018 section 2).

Per account only: relatives, viewers, editors and co-guardians have their own. Works with
``FEATURE_PAYMENTS=false`` (promo codes and admin grants need no store). The app caches the answer,
so it is never cached by an intermediary.
"""

from __future__ import annotations

from fastapi import APIRouter, Response

from app.deps import CurrentUser, NowDep, SessionDep, SettingsDep
from app.schemas.entitlements import EntitlementsOut
from app.services.entitlements import entitlements_out

router = APIRouter(prefix="/v1/me", tags=["me"])


@router.get("/entitlements")
async def get_entitlements(
    user: CurrentUser, session: SessionDep, settings: SettingsDep, now: NowDep, response: Response
) -> EntitlementsOut:
    response.headers["Cache-Control"] = "private, no-store"
    return await entitlements_out(session, settings, user.id, now)
