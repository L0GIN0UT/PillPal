"""Device records: when a device was last seen (shown to relatives only per hour, D5)."""

from __future__ import annotations

import uuid
from datetime import timedelta

from sqlalchemy import func
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import Device


async def touch_device_throttled(
    session: AsyncSession, user_id: uuid.UUID, device_id: str, min_interval: timedelta
) -> None:
    """Record the device (creating it) but rewrite ``last_seen_at`` at most once per interval."""
    stmt = pg_insert(Device).values(id=uuid.uuid4(), user_id=user_id, device_id=device_id)
    await session.execute(
        stmt.on_conflict_do_update(
            index_elements=[Device.user_id, Device.device_id],
            set_={"last_seen_at": func.now()},
            where=Device.last_seen_at < func.now() - min_interval,
        )
    )
