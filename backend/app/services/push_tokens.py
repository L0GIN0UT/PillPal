"""Registration of push tokens: one per device, reassignable between accounts (ADR 0008 §1).

The client decides *whether* to register (only while the user needs relative alerts,
ADR 0008 §1; milestone 3.9). The server accepts any well-formed token, within limits: a
fixed number per account, so the endpoint cannot be used to push to arbitrary tokens at
scale, and a provider the region does not use is refused.

A token that already belongs to another account (or another device of the same account) is
*reassigned* in the same transaction: the old row is deleted, which cascades its pending
deliveries. Accepted risk (ADR 0008 §1): whoever holds a device's token can take over its
relative alerts; the token is not a secret from the apps on the device.

Registrations of one account and registrations of one token are serialized by advisory
locks (always the account first), so the per-account cap and the token's uniqueness hold
under concurrency without retrying on constraint errors.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import and_, case, delete, func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.db.models import RefreshToken
from app.db.push import PushToken
from app.errors import AppError, validation_failed
from app.schemas.push import PushTokenIn
from app.services.devices import touch_device


def too_many_push_tokens() -> AppError:
    return AppError(409, "too_many_push_tokens", "This account has too many registered devices")


async def _lock(session: AsyncSession, key: str) -> None:
    await session.execute(select(func.pg_advisory_xact_lock(func.hashtextextended(key, 0))))


async def _others_count(
    session: AsyncSession, user_id: uuid.UUID, device_id: str, body: PushTokenIn
) -> int:
    """The account's tokens that stay after this registration, not counting this device."""
    stays = and_(
        PushToken.user_id == user_id,
        PushToken.device_id != device_id,
        # A token this registration takes over from a sibling device goes away.
        ~and_(PushToken.provider == body.provider, PushToken.token == body.token),
    )
    return int(await session.scalar(select(func.count()).select_from(PushToken).where(stays)) or 0)


async def register_token(
    session: AsyncSession,
    settings: Settings,
    user_id: uuid.UUID,
    device_id: str,
    body: PushTokenIn,
    now: datetime,
) -> PushToken:
    if body.provider == "rustore" and settings.region != "ru":
        raise validation_failed(("body", "provider"), "This provider is not available here")
    await touch_device(session, settings, user_id, device_id)
    await _lock(session, f"push_user:{user_id}")
    await _lock(session, f"push_token:{body.provider}:{body.token}")
    if await _others_count(session, user_id, device_id, body) >= settings.push_max_tokens_per_user:
        raise too_many_push_tokens()
    await session.execute(
        delete(PushToken).where(
            PushToken.provider == body.provider,
            PushToken.token == body.token,
            ~and_(PushToken.user_id == user_id, PushToken.device_id == device_id),
        )
    )
    insert = pg_insert(PushToken).values(
        id=uuid.uuid4(),
        user_id=user_id,
        device_id=device_id,
        provider=body.provider,
        token=body.token,
        apns_environment=body.apns_environment,
        created_at=now,
        updated_at=now,
    )
    unchanged = and_(
        PushToken.provider == insert.excluded.provider, PushToken.token == insert.excluded.token
    )
    stmt = insert.on_conflict_do_update(
        index_elements=[PushToken.user_id, PushToken.device_id],
        set_={
            "provider": insert.excluded.provider,
            "token": insert.excluded.token,
            "apns_environment": insert.excluded.apns_environment,
            "updated_at": now,
            # A new token has not succeeded yet (retention counts from the last success).
            "last_success_at": case((unchanged, PushToken.last_success_at), else_=None),
        },
    ).returning(PushToken)
    row = (await session.execute(stmt)).scalar_one()
    await session.commit()
    return row


async def delete_device_token(session: AsyncSession, user_id: uuid.UUID, device_id: str) -> None:
    """Forget the device's token (idempotent); the caller commits."""
    await session.execute(
        delete(PushToken).where(PushToken.user_id == user_id, PushToken.device_id == device_id)
    )


async def delete_family_tokens(
    session: AsyncSession, user_id: uuid.UUID, family_id: uuid.UUID
) -> None:
    """Forget the tokens of the devices a revoked refresh-token family was signed in on."""
    devices = select(RefreshToken.device_id).where(
        RefreshToken.family_id == family_id,
        RefreshToken.user_id == user_id,
        RefreshToken.device_id.is_not(None),
    )
    await session.execute(
        delete(PushToken).where(PushToken.user_id == user_id, PushToken.device_id.in_(devices))
    )


async def delete_user_tokens(session: AsyncSession, user_id: uuid.UUID) -> None:
    """Forget every token of the account (all its sessions were revoked); the caller commits."""
    await session.execute(delete(PushToken).where(PushToken.user_id == user_id))
