"""Creating an account row set: user, ``self`` profile and consent records.

Shared by e-mail registration and OAuth sign-up, so both write the same things in the same order.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.db.models import Profile, User
from app.domain.consents import ConsentSource
from app.services.changes import lock_journal, record_change
from app.services.consents import new_record
from app.services.devices import touch_device

DEFAULT_SELF_DISPLAY_NAME = "Me"


async def create_account(
    session: AsyncSession,
    settings: Settings,
    *,
    email: str,
    password_hash: str,
    locale: str,
    timezone: str,
    display_name: str | None,
    consents: list[tuple[str, int]],
    consent_source: ConsentSource,
    device_id: str | None,
    now: datetime,
    verified: bool = False,
) -> User | None:
    """The new user, or ``None`` if the e-mail got taken (the transaction is rolled back)."""
    user = User(
        id=uuid.uuid4(),
        email=email,
        password_hash=password_hash,
        region=settings.region,
        locale=locale,
        email_verified_at=now if verified else None,
        created_at=now,
        updated_at=now,
    )
    session.add(user)
    try:
        await session.flush()
    except IntegrityError:
        await session.rollback()
        return None
    await lock_journal(session, [user.id])
    profile = Profile(
        id=uuid.uuid4(),
        owner_user_id=user.id,
        kind="self",
        display_name=display_name or DEFAULT_SELF_DISPLAY_NAME,
        timezone=timezone,
        version=1,
        client_updated_at=now,
        updated_by_device=device_id or "",
    )
    session.add(profile)
    session.add_all(
        new_record(user.id, kind, version, consent_source, now) for kind, version in consents
    )
    await session.flush()
    await record_change(session, profile.id, "profile", profile.id, "upsert")
    await touch_device(session, settings, user.id, device_id)
    return user
