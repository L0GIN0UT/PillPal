"""Managed-profile archives (owner decision D1, ADR 0005 §5) and purging profile data.

When the owner of a managed profile asks to delete the account, the profile becomes a
read-only *archive* (``owner_pending_deletion``): co-guardians can read it and may only
leave. At the owner's hard erase it passes to the earliest *active* co-guardian
(``owner_erased``) and is kept ``MANAGED_ARCHIVE_RETENTION_DAYS``; without an active
co-guardian it is erased with the owner. Deleting an archive is a *purge*, not a tombstone:
every row of the profile goes, through the append-only trigger's ``pillpal.purge`` path.

All functions here run inside the caller's transaction, which already holds the journal
lock of every owner involved (``app.services.changes.lock_journal``).
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from datetime import datetime, timedelta

from sqlalchemy import delete, func, literal, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.alerts import MissedDoseAlert
from app.db.models import DoseEvent, Medication, Profile, Schedule, SyncChange, User
from app.db.relatives import Invite, ProfileGrant
from app.errors import AppError

PENDING_REASON = "owner_pending_deletion"
ERASED_REASON = "owner_erased"


def read_only() -> AppError:
    return AppError(409, "read_only", "This profile is an archive and can no longer be changed")


def is_archived(profile: Profile) -> bool:
    return profile.archived_at is not None


async def archive_owned_profiles(session: AsyncSession, owner_id: uuid.UUID, now: datetime) -> int:
    """Archive the live managed profiles of an owner who asked to delete the account.

    Already archived profiles are left alone: one that an earlier erasure handed to this
    owner (``owner_erased``) keeps its reason and purge date.
    """
    result = await session.execute(
        update(Profile)
        .where(
            Profile.owner_user_id == owner_id,
            Profile.kind == "managed",
            Profile.deleted_at.is_(None),
            Profile.archived_at.is_(None),
        )
        .values(archived_at=now, archive_reason=PENDING_REASON)
        .execution_options(synchronize_session=False)
    )
    return int(result.rowcount)  # type: ignore[attr-defined]


async def unarchive_owned_profiles(session: AsyncSession, owner_id: uuid.UUID) -> int:
    """Undo :func:`archive_owned_profiles` after a restore (deleted profiles stay as they are)."""
    result = await session.execute(
        update(Profile)
        .where(
            Profile.owner_user_id == owner_id,
            Profile.archive_reason == PENDING_REASON,
            Profile.deleted_at.is_(None),
        )
        .values(archived_at=None, archive_reason=None)
        .execution_options(synchronize_session=False)
    )
    return int(result.rowcount)  # type: ignore[attr-defined]


# --- hand-over at the owner's hard erase ------------------------------------------------------


async def candidate_heirs(session: AsyncSession, owner_id: uuid.UUID) -> set[uuid.UUID]:
    """Every guardian of the owner's live managed profiles (whose journal locks the erase takes)."""
    rows = await session.scalars(
        select(ProfileGrant.grantee_user_id)
        .join(Profile, Profile.id == ProfileGrant.profile_id)
        .where(
            Profile.owner_user_id == owner_id,
            Profile.kind == "managed",
            Profile.deleted_at.is_(None),
            ProfileGrant.role == "guardian",
        )
    )
    return set(rows)


async def _earliest_active_guardian(
    session: AsyncSession, profile_id: uuid.UUID
) -> uuid.UUID | None:
    """The co-guardian who inherits: earliest grant, not pending deletion (ADR 0005 §5)."""
    return await session.scalar(
        select(ProfileGrant.grantee_user_id)
        .join(User, User.id == ProfileGrant.grantee_user_id)
        .where(
            ProfileGrant.profile_id == profile_id,
            ProfileGrant.role == "guardian",
            User.deletion_requested_at.is_(None),
        )
        .order_by(ProfileGrant.created_at, ProfileGrant.id)
        .limit(1)
    )


async def _clear_device_ids(session: AsyncSession, profile_id: uuid.UUID) -> None:
    """Forget which devices wrote the rows: they belonged to the erased account's people."""
    medications = select(Medication.id).where(Medication.profile_id == profile_id)
    for stmt in (
        update(Profile).where(Profile.id == profile_id),
        update(Medication).where(Medication.profile_id == profile_id),
        update(Schedule).where(Schedule.medication_id.in_(medications)),
    ):
        await session.execute(
            stmt.values(updated_by_device="").execution_options(synchronize_session=False)
        )


async def transfer_owned_profiles(
    session: AsyncSession, owner_id: uuid.UUID, now: datetime, retention_days: int
) -> list[uuid.UUID]:
    """Hand each live managed profile of ``owner_id`` to its earliest active co-guardian.

    Returns the ids of the profiles that moved. Profiles without an active co-guardian stay
    and are erased with the owner. The heir's own grant disappears (an owner holds no grant),
    viewer and editor grants are deleted (they never survive the owner), the profile is an
    ``owner_erased`` archive purged at ``archive_purge_after``; a profile that already was
    one keeps its original purge date, so passing it on never extends the retention.
    """
    profile_ids = (
        await session.scalars(
            select(Profile.id)
            .where(
                Profile.owner_user_id == owner_id,
                Profile.kind == "managed",
                Profile.deleted_at.is_(None),
            )
            .order_by(Profile.created_at, Profile.id)
            .with_for_update()
        )
    ).all()
    moved: list[uuid.UUID] = []
    for profile_id in profile_ids:
        heir = await _earliest_active_guardian(session, profile_id)
        if heir is None:
            continue
        await session.execute(
            delete(ProfileGrant)
            .where(
                ProfileGrant.profile_id == profile_id,
                (ProfileGrant.grantee_user_id == heir) | (ProfileGrant.role != "guardian"),
            )
            .execution_options(synchronize_session=False)
        )
        await session.execute(
            update(Profile)
            .where(Profile.id == profile_id)
            .values(
                owner_user_id=heir,
                archived_at=func.coalesce(Profile.archived_at, literal(now)),
                archive_reason=ERASED_REASON,
                archive_purge_after=func.coalesce(
                    Profile.archive_purge_after, literal(now + timedelta(days=retention_days))
                ),
            )
            .execution_options(synchronize_session=False)
        )
        await _clear_device_ids(session, profile_id)
        moved.append(profile_id)
    return moved


# --- purge ------------------------------------------------------------------------------------


async def purge_profiles(session: AsyncSession, profile_ids: Sequence[uuid.UUID]) -> None:
    """Delete the profiles and every row hanging off them (not a tombstone).

    Dose events are append-only; their trigger lets DELETE through only while
    ``pillpal.purge`` is on, which ``set_config(..., true)`` confines to this transaction.
    """
    if not profile_ids:
        return
    ids = list(profile_ids)
    await session.execute(select(func.set_config("pillpal.purge", "on", True)))
    medications = select(Medication.id).where(Medication.profile_id.in_(ids)).scalar_subquery()
    statements = [
        delete(SyncChange).where(SyncChange.profile_id.in_(ids)),
        delete(MissedDoseAlert).where(MissedDoseAlert.profile_id.in_(ids)),
        # One statement: undo events reference events of the same profile.
        delete(DoseEvent).where(DoseEvent.profile_id.in_(ids)),
        delete(Schedule).where(Schedule.medication_id.in_(medications)),
        delete(Medication).where(Medication.profile_id.in_(ids)),
        delete(ProfileGrant).where(ProfileGrant.profile_id.in_(ids)),
        delete(Invite).where(Invite.profile_id.in_(ids)),
        delete(Profile).where(Profile.id.in_(ids)),
    ]
    for stmt in statements:
        await session.execute(stmt.execution_options(synchronize_session=False))


async def _owner_is_pending(session: AsyncSession, profile: Profile) -> bool:
    pending = await session.scalar(
        select(User.deletion_requested_at).where(User.id == profile.owner_user_id)
    )
    return pending is not None


async def purge_archive_if_erased(session: AsyncSession, profile: Profile) -> bool:
    """``DELETE /profiles/{id}`` on an archive: purge every row (no tombstone) once the former
    owner is erased and the current owner is not pending; otherwise guardians may only leave (409).
    Returns ``False`` for a live profile (the caller deletes it the usual way)."""
    if profile.archived_at is None:
        return False
    if profile.archive_reason != ERASED_REASON or await _owner_is_pending(session, profile):
        raise read_only()  # the (new) owner may still restore: guardians can only leave
    await purge_profiles(session, [profile.id])
    await session.commit()
    return True
