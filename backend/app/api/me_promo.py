"""``POST /v1/me/promo/redeem``: redeem a promo code for the signed-in account (ADR 0018 section 4).

Behind ``FEATURE_PROMO_CODES`` (403 ``feature_disabled``). Unknown, expired, exhausted, disabled
and malformed codes are one identical 400 ``invalid_promo_code``, each counted as a failure
(lockout, breaker). The answer is the account's entitlements, as in ``GET /v1/me/entitlements``.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request, Response

from app.api.me_entitlements import entitlements_out
from app.deps import CurrentUser, NowDep, RedisDep, SessionDep, SettingsDep
from app.errors import AppError, unauthorized
from app.ratelimit import client_ip
from app.schemas.entitlements import EntitlementsOut
from app.schemas.promo import PromoRedeemIn
from app.services.promo import RedeemOutcome, redeem_code
from app.services.promo_guard import PromoGuard

router = APIRouter(prefix="/v1/me/promo", tags=["me"])


def require_promo_feature(settings: SettingsDep) -> None:
    if not settings.feature_promo_codes:
        raise AppError(403, "feature_disabled", "This feature is not enabled")


@router.post(
    "/redeem",
    dependencies=[Depends(require_promo_feature)],
    responses={
        400: {"description": "invalid_promo_code: unknown, expired, exhausted or disabled"},
        403: {"description": "feature_disabled"},
        429: {"description": "rate_limited or promo_locked (see Retry-After)"},
        503: {"description": "promo_unavailable: Redis is down, or the breaker is blocking"},
    },
)
async def redeem(
    body: PromoRedeemIn,
    request: Request,
    response: Response,
    user: CurrentUser,
    session: SessionDep,
    settings: SettingsDep,
    redis: RedisDep,
    now: NowDep,
) -> EntitlementsOut:
    # The id is read now: the transaction ends inside the service and expires the user object.
    user_id = user.id
    guard = PromoGuard(redis, settings)
    await guard.check(user_id, client_ip(request))
    key = settings.promo_key_bytes()
    if key is None:  # development only: strict environments refuse to start without it
        raise AppError(503, "promo_unavailable", "Promo codes are temporarily unavailable")
    outcome = await redeem_code(session, user_id, body.code, key, now)
    if outcome is RedeemOutcome.ACCOUNT_GONE:
        raise unauthorized()
    if outcome is RedeemOutcome.REJECTED:
        await guard.record_failure(user_id)
        raise AppError(400, "invalid_promo_code", "This promo code cannot be used")
    response.headers["Cache-Control"] = "private, no-store"
    return await entitlements_out(session, user_id, now)
