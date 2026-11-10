"""Shared user-row access for services that must not import each other."""

from __future__ import annotations

import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import User


async def lock_user(session: AsyncSession, user_id: uuid.UUID) -> User | None:
    """The user row, locked until the transaction ends and freshly read.

    Sessions here do not autoflush, and the re-read overwrites the loaded instance: pending
    changes are flushed first (a verified e-mail must not be lost to the lock).
    """
    await session.flush()
    return await session.scalar(
        select(User)
        .where(User.id == user_id)
        .with_for_update(key_share=True)
        .execution_options(populate_existing=True)
    )
