"""Account erasure: deleting an account removes every row it owns (privacy, TZ §3).

One transaction deletes the journal, dose events, schedules, medications,
profiles, devices, refresh tokens, e-mail codes and finally the user. Dose
events are append-only; their trigger lets DELETE through only while
``pillpal.purge`` is ``on``, which is set with ``SET LOCAL`` semantics
(``set_config(..., true)``) so it ends with this transaction.
"""

from __future__ import annotations

import uuid

from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import (
    Device,
    DoseEvent,
    EmailCode,
    Medication,
    Profile,
    RefreshToken,
    Schedule,
    SyncChange,
    User,
)
from app.services.changes import lock_journal


async def erase_account(session: AsyncSession, user_id: uuid.UUID) -> None:
    """Delete the user and everything owned; the caller commits."""
    # Wait for in-flight writers of this user; nothing new is journaled after.
    await lock_journal(session, user_id)
    await session.execute(select(func.set_config("pillpal.purge", "on", True)))
    profile_ids = select(Profile.id).where(Profile.owner_user_id == user_id).scalar_subquery()
    medication_ids = (
        select(Medication.id).where(Medication.profile_id.in_(profile_ids)).scalar_subquery()
    )
    statements = [
        delete(SyncChange).where(SyncChange.user_id == user_id),
        # One statement: undo events reference events of the same account.
        delete(DoseEvent).where(DoseEvent.profile_id.in_(profile_ids)),
        delete(Schedule).where(Schedule.medication_id.in_(medication_ids)),
        delete(Medication).where(Medication.profile_id.in_(profile_ids)),
        delete(Profile).where(Profile.owner_user_id == user_id),
        delete(Device).where(Device.user_id == user_id),
        delete(RefreshToken).where(RefreshToken.user_id == user_id),
        delete(EmailCode).where(EmailCode.user_id == user_id),
        delete(User).where(User.id == user_id),
    ]
    for stmt in statements:
        await session.execute(stmt.execution_options(synchronize_session=False))
