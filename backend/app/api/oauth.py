"""/v1/auth/providers and /v1/auth/oauth/* (ADR 0017)."""

from __future__ import annotations

from typing import Annotated, Literal, cast

from fastapi import APIRouter, Depends, Request, Response, status

from app.api.reauth_dep import get_registry
from app.deps import (
    EmailSenderDep,
    HasherDep,
    NowDep,
    OptionalDeviceId,
    RedisDep,
    SessionDep,
    SettingsDep,
    TokensDep,
)
from app.domain.auth_providers import Platform
from app.errors import not_found
from app.oauth.registry import ProviderRegistry
from app.ratelimit import (
    RateLimiter,
    client_ip,
    limit_by_body_field,
    limit_by_email,
    limit_by_ip,
)
from app.schemas.auth import OAuthVerificationSent, TokenPair
from app.schemas.oauth import (
    NonceOut,
    NonceRequest,
    OAuthSignInRequest,
    OAuthSignUpRequest,
    ProviderOut,
    ProvidersOut,
)
from app.services.oauth_sign_in import OAuthService
from app.services.oauth_state import OAuthState

router = APIRouter(prefix="/v1/auth", tags=["oauth"])

ProviderName = Literal["apple", "google", "vk_id", "yandex_id"]


def require_oauth(settings: SettingsDep) -> None:
    """Every OAuth route is a 404 while the feature is off."""
    if not settings.feature_oauth:
        raise not_found()


async def limit_nonce(request: Request) -> None:
    """Per IP, and per account when the caller sends a valid access token (link, re-auth)."""
    limiter: RateLimiter = request.app.state.rate_limiter
    token = request.headers.get("Authorization", "").partition(" ")[2].strip()
    claims = request.app.state.tokens.decode_access(token)
    await limiter.check(
        "oauth_nonce",
        client_ip(request),
        str(claims.user_id) if claims is not None else None,
        per_account=True,
    )


def get_oauth_service(
    session: SessionDep,
    settings: SettingsDep,
    tokens: TokensDep,
    hasher: HasherDep,
    email_sender: EmailSenderDep,
    redis: RedisDep,
    registry: Annotated[ProviderRegistry, Depends(get_registry)],
) -> OAuthService:
    return OAuthService(session, settings, tokens, hasher, email_sender, redis, registry)


OAuth = Annotated[OAuthService, Depends(get_oauth_service)]


@router.get("/providers", dependencies=[Depends(limit_by_ip("oauth_providers"))])
async def list_providers(
    registry: Annotated[ProviderRegistry, Depends(get_registry)], platform: Platform
) -> ProvidersOut:
    """The providers this region offers on ``platform`` (empty while the feature is off)."""
    return ProvidersOut(
        providers=[
            ProviderOut(provider=cast(ProviderName, name)) for name in registry.available(platform)
        ]
    )


@router.post(
    "/oauth/nonce",
    dependencies=[Depends(require_oauth), Depends(limit_nonce)],
    responses={503: {"description": "provider_unreachable: the nonce store is down"}},
)
async def issue_nonce(body: NonceRequest, redis: RedisDep, settings: SettingsDep) -> NonceOut:
    """A single-use server nonce for one purpose; the ID token must carry its sha256."""
    nonce = await OAuthState(redis, settings).issue_nonce(body.purpose)
    return NonceOut(nonce=nonce, expires_in=settings.oauth_nonce_ttl_seconds)


@router.post(
    "/oauth/sign-up",
    status_code=status.HTTP_201_CREATED,
    dependencies=[
        Depends(require_oauth),
        Depends(limit_by_ip("oauth_sign_up_ip")),
        Depends(limit_by_body_field("oauth_sign_up", "signup_ticket")),
        # The 202 path mails a code: it shares the per-address budget of ``register``.
        Depends(limit_by_email("register", optional=True)),
    ],
    responses={
        202: {
            "model": OAuthVerificationSent,
            "description": "no verified address: code mailed; send pending_token with the code "
            "to verify-email to link the provider",
        },
        401: {"description": "invalid_provider_token: unknown, used or stale ticket"},
        409: {"description": "oauth_account_exists"},
        503: {"description": "provider_unreachable"},
    },
)
async def oauth_sign_up(
    body: OAuthSignUpRequest,
    oauth: OAuth,
    now: NowDep,
    response: Response,
    device_id: OptionalDeviceId = None,
) -> TokenPair | OAuthVerificationSent:
    """Finish sign-up with the ticket of a 409 ``oauth_signup_required``.

    201 with tokens for a provider-verified address; 202 when the provider verified none (the
    mailed code is entered at ``POST /v1/auth/verify-email``).
    """
    result = await oauth.sign_up(body, device_id, now)
    if isinstance(result, OAuthVerificationSent):
        response.status_code = status.HTTP_202_ACCEPTED
    return result


@router.post(
    "/oauth/{provider}/sign-in",
    dependencies=[Depends(require_oauth), Depends(limit_by_ip("oauth_sign_in"))],
    responses={
        401: {"description": "invalid_provider_token"},
        403: {
            "description": "account_pending_deletion with details.restore_ticket and "
            "details.erase_after"
        },
        404: {"description": "provider not configured or not offered for this region or platform"},
        409: {
            "description": "oauth_account_exists, or oauth_signup_required with "
            "details.signup_ticket and details.email_required; a retry needs a new nonce and a "
            "new assertion (the first ones are spent)"
        },
        503: {"description": "provider_unreachable"},
    },
)
async def oauth_sign_in(
    provider: str,
    body: OAuthSignInRequest,
    oauth: OAuth,
    now: NowDep,
    device_id: OptionalDeviceId = None,
) -> TokenPair:
    return await oauth.sign_in(provider, body, device_id, now)
