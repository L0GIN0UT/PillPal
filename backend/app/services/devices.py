"""Device records: when a device was last seen (shown to relatives only per hour, D5).

``X-Device-ID`` is chosen by the client, so the rows are capped per user
(``Settings.max_devices_per_user``). A new id over the cap is refused with
``409 too_many_devices``, after forgetting devices unseen for
``device_stale_after_days`` (reinstalling the app makes a new id). The check and
the insert are separate statements, so concurrent requests with several new ids
can overshoot the cap by a few rows; the cap bounds growth, it is not exact.
"""

from __future__ import annotations

import uuid
from datetime import timedelta

from sqlalchemy import delete, func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.db.models import Device
from app.errors import AppError


def too_many_devices() -> AppError:
    return AppError(409, "too_many_devices", "This account has too many registered devices")


async def _ensure_room(
    session: AsyncSession, settings: Settings, user_id: uuid.UUID, device_id: str
) -> None:
    known = await session.scalar(
        select(Device.id).where(Device.user_id == user_id, Device.device_id == device_id)
    )
    if known is not None:
        return
    count = select(func.count()).select_from(Device).where(Device.user_id == user_id)
    if int(await session.scalar(count) or 0) < settings.max_devices_per_user:
        return
    stale = timedelta(days=settings.device_stale_after_days)
    await session.execute(
        delete(Device).where(Device.user_id == user_id, Device.last_seen_at < func.now() - stale)
    )
    if int(await session.scalar(count) or 0) >= settings.max_devices_per_user:
        raise too_many_devices()


async def touch_device(
    session: AsyncSession, settings: Settings, user_id: uuid.UUID, device_id: str | None
) -> None:
    """Record the device (creating it) and its last-seen time."""
    if device_id is None:
        return
    await _ensure_room(session, settings, user_id, device_id)
    stmt = pg_insert(Device).values(id=uuid.uuid4(), user_id=user_id, device_id=device_id)
    await session.execute(
        stmt.on_conflict_do_update(
            index_elements=[Device.user_id, Device.device_id],
            set_={"last_seen_at": func.now()},
        )
    )


async def touch_device_throttled(
    session: AsyncSession, settings: Settings, user_id: uuid.UUID, device_id: str
) -> None:
    """Like :func:`touch_device`, but ``last_seen_at`` is rewritten at most once per interval."""
    await _ensure_room(session, settings, user_id, device_id)
    interval = timedelta(seconds=settings.device_touch_interval_seconds)
    stmt = pg_insert(Device).values(id=uuid.uuid4(), user_id=user_id, device_id=device_id)
    await session.execute(
        stmt.on_conflict_do_update(
            index_elements=[Device.user_id, Device.device_id],
            set_={"last_seen_at": func.now()},
            where=Device.last_seen_at < func.now() - interval,
        )
    )
