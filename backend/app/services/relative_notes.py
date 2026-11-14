"""Private notes about relatives (ADR 0020 section 4).

A note is a short label ("Сын") that only its author ever reads. It is keyed by
``(author, subject profile)``: a person with an account is addressed by their self profile, a
managed profile by its own id. A note may exist only while the author and the subject are
related:

* *incoming*: the author holds a grant on the subject profile (someone else's);
* *outgoing*: the subject is the self profile of an account that holds a grant on a live
  profile the author owns.

Writes need the relationship to be visible to the author (an incoming grant must be active, as in
``GET /v1/grants``); anything else is 404 like a missing profile. When a grant goes,
``prune_notes`` drops the notes of both parties that lost their last relationship; the daily
retention sweep (``sweep_orphan_notes``) catches every other way a relationship ends (profile
deleted, ownership handed over). The note text is never logged.
"""

from __future__ import annotations

import uuid
from collections.abc import Collection
from datetime import datetime

from sqlalchemy import ColumnElement, and_, delete, exists, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import InstrumentedAttribute, aliased

from app.config import Settings
from app.db.models import Profile
from app.db.relatives import ProfileGrant, RelativeNote
from app.errors import AppError, not_found
from app.observability import get_logger
from app.schemas.relatives import RelativeNoteOut
from app.services.access import grant_is_active

_log = get_logger("pillpal.relative_notes")

UserRef = uuid.UUID | ColumnElement[uuid.UUID] | InstrumentedAttribute[uuid.UUID]


def too_many_notes() -> AppError:
    return AppError(409, "too_many_notes", "Too many notes about relatives")


def _holds_grant(author: UserRef, subject: UserRef, *, active: bool) -> ColumnElement[bool]:
    """Incoming: ``author`` holds a grant on the live profile ``subject`` of someone else."""
    conditions = [
        ProfileGrant.profile_id == subject,
        ProfileGrant.grantee_user_id == author,
        Profile.deleted_at.is_(None),
        Profile.owner_user_id != author,
    ]
    if active:
        conditions.append(grant_is_active())
    return exists(
        select(ProfileGrant.id)
        .join(Profile, Profile.id == ProfileGrant.profile_id)
        .where(*conditions)
    )


def _grantee_of_mine(author: UserRef, subject: UserRef) -> ColumnElement[bool]:
    """Outgoing: ``subject`` is the self profile of a grantee on a live profile ``author`` owns."""
    owned = aliased(Profile)
    grantee_self = aliased(Profile)
    return exists(
        select(ProfileGrant.id)
        .join(owned, owned.id == ProfileGrant.profile_id)
        .join(
            grantee_self,
            and_(
                grantee_self.owner_user_id == ProfileGrant.grantee_user_id,
                grantee_self.kind == "self",
                grantee_self.deleted_at.is_(None),
            ),
        )
        .where(
            grantee_self.id == subject,
            owned.owner_user_id == author,
            owned.deleted_at.is_(None),
        )
    )


def related(author: UserRef, subject: UserRef, *, active: bool) -> ColumnElement[bool]:
    return or_(_holds_grant(author, subject, active=active), _grantee_of_mine(author, subject))


async def _ensure_related(session: AsyncSession, user_id: uuid.UUID, profile_id: uuid.UUID) -> None:
    if not await session.scalar(select(related(user_id, profile_id, active=True))):
        raise not_found()


def _out(row: RelativeNote) -> RelativeNoteOut:
    return RelativeNoteOut(
        profile_id=row.subject_profile_id, note=row.note, updated_at=row.updated_at
    )


async def put_note(
    session: AsyncSession,
    settings: Settings,
    now: datetime,
    user_id: uuid.UUID,
    profile_id: uuid.UUID,
    note: str,
) -> RelativeNoteOut:
    """Create or replace the caller's note; the same text again changes nothing (idempotent)."""
    await _ensure_related(session, user_id, profile_id)
    # Serialize one author's writers so concurrent creates cannot exceed the cap.
    await session.execute(
        select(func.pg_advisory_xact_lock(func.hashtextextended(f"notes:{user_id}", 0)))
    )
    row = await session.get(RelativeNote, (user_id, profile_id), with_for_update=True)
    if row is None:
        count = await session.scalar(
            select(func.count()).select_from(RelativeNote).where(RelativeNote.user_id == user_id)
        )
        if int(count or 0) >= settings.max_relative_notes_per_user:
            raise too_many_notes()
        row = RelativeNote(
            user_id=user_id,
            subject_profile_id=profile_id,
            note=note,
            created_at=now,
            updated_at=now,
        )
        session.add(row)
    elif row.note != note:
        row.note = note
        row.updated_at = now
    await session.flush()
    out = _out(row)
    await session.commit()
    _log.info("relative_note_saved", subject_profile_id=str(profile_id))
    return out


async def delete_note(session: AsyncSession, user_id: uuid.UUID, profile_id: uuid.UUID) -> None:
    """Delete the caller's note (idempotent while related); 404 when unrelated and no note."""
    result = await session.execute(
        delete(RelativeNote)
        .where(RelativeNote.user_id == user_id, RelativeNote.subject_profile_id == profile_id)
        .execution_options(synchronize_session=False)
    )
    if not int(result.rowcount):  # type: ignore[attr-defined]
        await _ensure_related(session, user_id, profile_id)
    await session.commit()


async def notes_about(
    session: AsyncSession, user_id: uuid.UUID, subject_ids: Collection[uuid.UUID]
) -> list[RelativeNoteOut]:
    """The caller's notes about the given subjects (the ones ``GET /v1/grants`` lists)."""
    if not subject_ids:
        return []
    rows = await session.scalars(
        select(RelativeNote)
        .where(
            RelativeNote.user_id == user_id,
            RelativeNote.subject_profile_id.in_(list(subject_ids)),
        )
        .order_by(RelativeNote.subject_profile_id)
    )
    return [_out(row) for row in rows]


def _orphaned() -> ColumnElement[bool]:
    # Structural relation only: a paused or pending grant comes back, and so does its note.
    return ~related(RelativeNote.user_id, RelativeNote.subject_profile_id, active=False)


async def prune_notes(session: AsyncSession, user_ids: Collection[uuid.UUID]) -> int:
    """Delete the notes of these authors that lost their last relationship (the caller commits)."""
    if not user_ids:
        return 0
    result = await session.execute(
        delete(RelativeNote)
        .where(RelativeNote.user_id.in_(list(user_ids)), _orphaned())
        .execution_options(synchronize_session=False)
    )
    return int(result.rowcount)  # type: ignore[attr-defined]


async def sweep_orphan_notes(session: AsyncSession) -> int:
    """Daily retention: every note whose author and subject are no longer related."""
    result = await session.execute(
        delete(RelativeNote).where(_orphaned()).execution_options(synchronize_session=False)
    )
    return int(result.rowcount)  # type: ignore[attr-defined]
