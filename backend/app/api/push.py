"""Push token registration (ADR 0008 §1): a device registers and removes its own token.

Whether to register is the client's decision (only while the user needs alerts about
relatives, milestone 3.9); the server accepts any well-formed token within the limits.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Response, status

from app.deps import (
    CurrentUser,
    NowDep,
    RequiredDeviceId,
    SessionDep,
    SettingsDep,
    limit_by_user,
)
from app.schemas.push import PushTokenIn, PushTokenOut
from app.services import push_tokens

router = APIRouter(prefix="/v1/push-tokens", tags=["push"])


@router.put(
    "/current",
    dependencies=[Depends(limit_by_user("push_token"))],
    responses={409: {"description": "too_many_push_tokens, too_many_devices"}},
)
async def register_current_token(
    body: PushTokenIn,
    user: CurrentUser,
    device_id: RequiredDeviceId,
    session: SessionDep,
    settings: SettingsDep,
    now: NowDep,
) -> PushTokenOut:
    """Register (or replace) this device's push token. The token is never returned."""
    row = await push_tokens.register_token(session, settings, user.id, device_id, body, now)
    return PushTokenOut(
        provider=row.provider,
        apns_environment=row.apns_environment,
        updated_at=row.updated_at,
    )


@router.delete(
    "/current",
    status_code=status.HTTP_204_NO_CONTENT,
    dependencies=[Depends(limit_by_user("push_token"))],
)
async def delete_current_token(
    user: CurrentUser, device_id: RequiredDeviceId, session: SessionDep
) -> Response:
    """Remove this device's push token (no relative alerts are needed any more)."""
    await push_tokens.delete_device_token(session, user.id, device_id)
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
