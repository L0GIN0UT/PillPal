"""``POST /v1/me/purchases``: claim a store purchase for the signed-in account (ADR 0018 section 6).

Behind ``FEATURE_PAYMENTS`` (403 ``feature_disabled``). The proof is verified offline (StoreKit 2)
against the account's own ``appAccountToken``, so a transaction bought for another account is
``invalid_purchase``. A verified purchase grants what its product grants (both kinds for the
remove-ads product): 201; the same account again: 200; the same purchase held by another account:
409 ``purchase_already_claimed``. RuStore Pay and Google Play are stubs: 503 ``store_unavailable``.
The signed transaction is neither stored nor logged; the answer is the account's entitlements.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request, Response

from app.deps import CurrentUser, NowDep, SessionDep, SettingsDep
from app.errors import AppError, unauthorized
from app.observability import get_logger
from app.payments.base import InvalidPurchase, StoreUnavailable
from app.payments.registry import PaymentRegistry
from app.ratelimit import RateLimiter, client_ip
from app.schemas.entitlements import EntitlementsOut
from app.schemas.purchases import PurchaseIn
from app.services.entitlements import entitlements_out
from app.services.purchases import ClaimOutcome, verify_and_claim

router = APIRouter(prefix="/v1/me", tags=["me"])
_log = get_logger("pillpal.purchases")

PURCHASE_RATE_SCOPE = "purchase"


def require_payments_feature(settings: SettingsDep) -> None:
    if not settings.feature_payments:
        raise AppError(403, "feature_disabled", "This feature is not enabled")


async def limit_purchases(request: Request, user: CurrentUser, settings: SettingsDep) -> None:
    limiter: RateLimiter = request.app.state.rate_limiter
    await limiter.check(
        PURCHASE_RATE_SCOPE,
        client_ip(request),
        str(user.id),
        per_account=True,
        limit=settings.payments_rate_limit_attempts,
        window=settings.payments_rate_limit_window_seconds,
        fail_closed=True,  # with Redis down the claim is refused (503), never unlimited
    )


@router.post(
    "/purchases",
    status_code=201,
    dependencies=[Depends(require_payments_feature), Depends(limit_purchases)],
    responses={
        200: {"description": "The account had already claimed this purchase"},
        400: {"description": "invalid_purchase: the proof is not a valid purchase of this account"},
        403: {"description": "feature_disabled"},
        409: {"description": "purchase_already_claimed: held by another account"},
        413: {"description": "payload_too_large (PAYMENTS_MAX_BODY_BYTES)"},
        429: {"description": "rate_limited"},
        503: {"description": "store_unavailable: no working verifier for this store yet"},
    },
)
async def claim(
    body: PurchaseIn,
    request: Request,
    response: Response,
    user: CurrentUser,
    session: SessionDep,
    settings: SettingsDep,
    now: NowDep,
) -> EntitlementsOut:
    # The id is read now: the transaction ends inside the service and expires the user object.
    user_id = user.id
    # The proof lives under this name only (log and error-tracker scrubbers filter it by name),
    # and the body model, which would repr it in a frame dump, is dropped.
    store, proof = body.store, body.proof
    del body
    registry: PaymentRegistry = request.app.state.payment_registry
    try:
        outcome = await verify_and_claim(session, registry, settings, user_id, store, proof, now)
    except StoreUnavailable:
        raise AppError(503, "store_unavailable", "This store is not available yet") from None
    except InvalidPurchase:
        raise _invalid() from None
    if outcome is ClaimOutcome.ACCOUNT_GONE:
        raise unauthorized()
    if outcome is ClaimOutcome.CLAIMED_BY_OTHER:
        _log.info("purchase_already_claimed", store=store)
        raise AppError(409, "purchase_already_claimed", "This purchase belongs to another account")
    if outcome is ClaimOutcome.REPLAYED:
        response.status_code = 200
    response.headers["Cache-Control"] = "private, no-store"
    return await entitlements_out(session, settings, user_id, now)


def _invalid() -> AppError:
    return AppError(400, "invalid_purchase", "This purchase cannot be accepted")
