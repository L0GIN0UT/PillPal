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
    LoginRequest,
    PasswordResetConfirm,
    PasswordResetRequest,
    RefreshRequest,
    RegisterRequest,
    RegisterResponse,
    TokenPair,
    UserOut,
    VerifyEmailRequest,
)
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
    status_code=status.HTTP_201_CREATED,
    dependencies=[Depends(limit_by_email("register"))],
    responses={409: {"description": "wrong_region | email_taken"}},
)
async def register(
    body: RegisterRequest, auth: Auth, device_id: OptionalDeviceId = None
) -> RegisterResponse:
    user, tokens = await auth.register(body, device_id)
    return RegisterResponse(user=user_out(user), tokens=tokens)


@router.post("/login", dependencies=[Depends(limit_by_email("login"))])
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


@router.post(
    "/verify-email",
    status_code=status.HTTP_204_NO_CONTENT,
    dependencies=[Depends(limit_by_user("verify_email"))],
)
async def verify_email(body: VerifyEmailRequest, user: CurrentUser, auth: Auth) -> Response:
    await auth.verify_email(user, body.code)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post(
    "/verify-email/resend",
    status_code=status.HTTP_202_ACCEPTED,
    dependencies=[Depends(limit_by_user("verify_email_resend"))],
)
async def resend_verification(user: CurrentUser, auth: Auth) -> Accepted:
    await auth.resend_verification(user)
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


@me_router.delete("", status_code=status.HTTP_204_NO_CONTENT)
async def delete_me(user: CurrentUser, auth: Auth) -> Response:
    await auth.delete_account(user)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
