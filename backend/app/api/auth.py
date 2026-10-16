"""/v1/auth/* and /v1/me."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Response, status

from app.db.models import User
from app.deps import (
    CurrentUser,
    EmailSenderDep,
    HasherDep,
    OptionalDeviceId,
    SessionDep,
    SettingsDep,
    TokensDep,
    limit_by_user,
)
from app.ratelimit import limit_by_email, limit_by_ip
from app.schemas.auth import (
    Accepted,
    DeleteAccountRequest,
    LoginRequest,
    PasswordResetConfirm,
    PasswordResetRequest,
    RefreshRequest,
    RegisterRequest,
    ResendVerificationRequest,
    TokenPair,
    UserOut,
    VerificationSent,
    VerifyEmailRequest,
)
from app.schemas.relatives import FeaturesOut
from app.services.auth import AuthService

router = APIRouter(prefix="/v1/auth", tags=["auth"])
me_router = APIRouter(prefix="/v1/me", tags=["me"])


def get_auth_service(
    session: SessionDep,
    settings: SettingsDep,
    tokens: TokensDep,
    hasher: HasherDep,
    email_sender: EmailSenderDep,
) -> AuthService:
    return AuthService(session, settings, tokens, hasher, email_sender)


Auth = Annotated[AuthService, Depends(get_auth_service)]


def user_out(user: User) -> UserOut:
    return UserOut(
        id=user.id,
        email=user.email,
        email_verified=user.email_verified_at is not None,
        region=user.region,
        locale=user.locale,
        created_at=user.created_at,
    )


@router.post(
    "/register",
    status_code=status.HTTP_202_ACCEPTED,
    dependencies=[Depends(limit_by_email("register"))],
    responses={409: {"description": "wrong_region"}},
)
async def register(
    body: RegisterRequest, auth: Auth, device_id: OptionalDeviceId = None
) -> VerificationSent:
    """Always 202 with the same body: a known e-mail gets an "account exists" mail instead.

    Finish with ``POST /v1/auth/verify-email``, which returns the first token pair.
    """
    await auth.register(body, device_id)
    return VerificationSent()


@router.post(
    "/login",
    dependencies=[Depends(limit_by_email("login"))],
    responses={403: {"description": "email_not_verified (after a correct password)"}},
)
async def login(body: LoginRequest, auth: Auth, device_id: OptionalDeviceId = None) -> TokenPair:
    return await auth.login(body.email, body.password, device_id)


@router.post("/refresh", dependencies=[Depends(limit_by_ip("refresh"))])
async def refresh(
    body: RefreshRequest, auth: Auth, device_id: OptionalDeviceId = None
) -> TokenPair:
    return await auth.refresh(body.refresh_token, device_id)


@router.post(
    "/logout",
    status_code=status.HTTP_204_NO_CONTENT,
    dependencies=[Depends(limit_by_ip("logout"))],
)
async def logout(body: RefreshRequest, auth: Auth) -> Response:
    await auth.logout(body.refresh_token)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/verify-email", dependencies=[Depends(limit_by_email("verify_email"))])
async def verify_email(
    body: VerifyEmailRequest, auth: Auth, device_id: OptionalDeviceId = None
) -> TokenPair:
    """Confirm the e-mail with the mailed code; returns the first token pair."""
    return await auth.verify_email(body.email, body.code, device_id)


@router.post(
    "/verify-email/resend",
    status_code=status.HTTP_202_ACCEPTED,
    dependencies=[Depends(limit_by_email("verify_email_resend"))],
)
async def resend_verification(body: ResendVerificationRequest, auth: Auth) -> Accepted:
    # Same response whether or not the account exists or is already verified.
    await auth.resend_verification(body.email)
    return Accepted()


@router.post(
    "/password-reset/request",
    status_code=status.HTTP_202_ACCEPTED,
    dependencies=[Depends(limit_by_email("password_reset_request"))],
)
async def password_reset_request(body: PasswordResetRequest, auth: Auth) -> Accepted:
    # Same response whether or not the account exists.
    await auth.request_password_reset(body.email)
    return Accepted()


@router.post(
    "/password-reset/confirm",
    status_code=status.HTTP_204_NO_CONTENT,
    dependencies=[Depends(limit_by_email("password_reset_confirm"))],
)
async def password_reset_confirm(body: PasswordResetConfirm, auth: Auth) -> Response:
    await auth.confirm_password_reset(body.email, body.code, body.new_password)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@me_router.get("")
async def get_me(user: CurrentUser) -> UserOut:
    return user_out(user)


@me_router.get("/features")
async def get_features(_: CurrentUser, settings: SettingsDep) -> FeaturesOut:
    """What the app gates behind soft limits (TZ §1); limits are null while the flag is off."""
    on = settings.feature_soft_limits
    return FeaturesOut(
        soft_limits_enabled=on,
        relatives_limit=settings.soft_limit_relatives if on else None,
        pdf_reports_limit=settings.soft_limit_pdf_reports if on else None,
    )


@me_router.delete(
    "",
    status_code=status.HTTP_204_NO_CONTENT,
    dependencies=[Depends(limit_by_user("delete_account"))],
    responses={401: {"description": "invalid_password"}},
)
async def delete_me(body: DeleteAccountRequest, user: CurrentUser, auth: Auth) -> Response:
    """Erase the account and all its data (irreversible); requires the current password."""
    await auth.delete_account(user, body.password)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
