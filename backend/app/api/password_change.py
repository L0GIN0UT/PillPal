"""``/v1/auth/password-change/*``: change the password of a signed-in account with a mailed code.

Both routes need the session of the access token (``sid``): the code is bound to that session.
The request re-authenticates with the current password (the budget of ``/restore`` per address,
and the account's login bucket against guessing); the confirm sets the new password, ends every
other session and keeps this one (refresh token and session stay valid, the access token is
replaced through ``POST /v1/auth/refresh``).
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Response, status

from app.api.auth import Auth
from app.deps import CurrentUser, SessionId, limit_by_user, limit_reauth
from app.ratelimit import limit_by_ip
from app.schemas.auth import Accepted, PasswordChangeConfirm, PasswordChangeRequest

router = APIRouter(prefix="/v1/auth/password-change", tags=["auth"])


@router.post(
    "/request",
    status_code=status.HTTP_202_ACCEPTED,
    dependencies=[
        Depends(limit_by_ip("password_change_ip")),
        Depends(limit_reauth("password_change_request")),
    ],
    responses={
        401: {"description": "invalid_password, or invalid_token (no or ended session)"},
        503: {"description": "rate_limit_unavailable"},
    },
)
async def password_change_request(
    body: PasswordChangeRequest, user: CurrentUser, session_id: SessionId, auth: Auth
) -> Accepted:
    """Mail a code bound to this session after the current password checked out. Always 202,
    also when the per-account cap of codes is reached (nothing is mailed then)."""
    await auth.request_password_change(user, session_id, body.current_password)
    return Accepted()


@router.post(
    "/confirm",
    status_code=status.HTTP_204_NO_CONTENT,
    dependencies=[Depends(limit_by_user("password_change_confirm"))],
    responses={400: {"description": "invalid_code: wrong, expired, spent or another session's"}},
)
async def password_change_confirm(
    body: PasswordChangeConfirm, user: CurrentUser, session_id: SessionId, auth: Auth
) -> Response:
    """Set the new password and end every other session (their push tokens go too); this
    session stays signed in. The mailed code is single use."""
    await auth.confirm_password_change(user.id, session_id, body.code, body.new_password)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
