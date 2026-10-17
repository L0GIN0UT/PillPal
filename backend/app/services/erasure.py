"""Hard erase of an account: deleting it removes every row it owns (privacy, TZ §3).

This is the second stage of account deletion (ADR 0010 §5): the hourly job calls it for
accounts whose grace period is over; ``DELETE /v1/me`` only *requests* deletion
(``app.services.account_deletion``). One transaction:

1. takes the journal lock of the account and of every co-guardian who might inherit, in
   sorted order;
2. hands each managed profile with an *active* co-guardian to the earliest one (D1,
   ``app.services.archives``), keeping it as an archive;
3. forgets the account's device ids on rows in foreign profiles (``updated_by_device``);
4. deletes everything else the account owns: grants in both directions, invites (rows it
   consumed for others only forget it, ``consumed_by_user_id`` is ``ON DELETE SET NULL``),
   push tokens and outbox rows (addressed to the account or about its profiles), journal,
   dose events, schedules, medications, profiles, devices, refresh tokens, e-mail codes and
   the user.

``app.services.personal_data`` lists every table; a test checks that none keeps a row of the
erased account. The caller holds the user row lock and commits.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import delete, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import Device, EmailCode, Medication, Profile, RefreshToken, Schedule, User
from app.db.push import PushOutbox, PushToken
from app.db.relatives import Invite, ProfileGrant
from app.services.archives import candidate_heirs, purge_profiles, transfer_owned_profiles
from app.services.changes import lock_journal


async def _forget_devices_on_foreign_rows(session: AsyncSession, user_id: uuid.UUID) -> None:
    """Blank ``updated_by_device`` of this account's devices on profiles it does not own.

    Dose events are append-only (their trigger rejects UPDATE), so their ``device_id`` stays;
    it is an opaque client string and the ``devices`` row that tied it to the account goes.
    """
    device_ids = (
        await session.scalars(select(Device.device_id).where(Device.user_id == user_id))
    ).all()
    if not device_ids:
        return
    foreign = select(Profile.id).where(Profile.owner_user_id != user_id)
    medications = select(Medication.id).where(Medication.profile_id.in_(foreign))
    for stmt in (
        update(Profile).where(
            Profile.owner_user_id != user_id, Profile.updated_by_device.in_(device_ids)
        ),
        update(Medication).where(
            Medication.profile_id.in_(foreign), Medication.updated_by_device.in_(device_ids)
        ),
        update(Schedule).where(
            Schedule.medication_id.in_(medications), Schedule.updated_by_device.in_(device_ids)
        ),
    ):
        await session.execute(
            stmt.values(updated_by_device="").execution_options(synchronize_session=False)
        )


async def erase_account(
    session: AsyncSession,
    user_id: uuid.UUID,
    *,
    now: datetime,
    managed_archive_retention_days: int,
) -> None:
    """Hand over, then delete the user and everything owned; the caller commits."""
    # Wait for in-flight writers of this user and of every possible heir; nothing new is
    # journaled in these scopes after. All locks in one sorted call (no lock-order cycles).
    heirs = await candidate_heirs(session, user_id)
    await lock_journal(session, {user_id, *heirs})
    await transfer_owned_profiles(session, user_id, now, managed_archive_retention_days)
    await _forget_devices_on_foreign_rows(session, user_id)
    owned = (
        await session.scalars(select(Profile.id).where(Profile.owner_user_id == user_id))
    ).all()
    # Links in both directions: the grants the account holds and the grants on its profiles,
    # and the invites it created or that point at its profiles.
    await session.execute(
        delete(ProfileGrant)
        .where(or_(ProfileGrant.grantee_user_id == user_id, ProfileGrant.profile_id.in_(owned)))
        .execution_options(synchronize_session=False)
    )
    await session.execute(
        delete(Invite)
        .where(or_(Invite.created_by_user_id == user_id, Invite.profile_id.in_(owned)))
        .execution_options(synchronize_session=False)
    )
    # Push data both ways (the FKs cascade as well; this keeps the list of what is erased
    # in one place): pushes addressed to the account or about its profiles, then its tokens.
    await session.execute(
        delete(PushOutbox)
        .where(
            or_(PushOutbox.recipient_user_id == user_id, PushOutbox.subject_profile_id.in_(owned))
        )
        .execution_options(synchronize_session=False)
    )
    await session.execute(
        delete(PushToken)
        .where(PushToken.user_id == user_id)
        .execution_options(synchronize_session=False)
    )
    await purge_profiles(session, owned)
    for stmt in (
        delete(Device).where(Device.user_id == user_id),
        delete(RefreshToken).where(RefreshToken.user_id == user_id),
        delete(EmailCode).where(EmailCode.user_id == user_id),
        delete(User).where(User.id == user_id),
    ):
        await session.execute(stmt.execution_options(synchronize_session=False))
