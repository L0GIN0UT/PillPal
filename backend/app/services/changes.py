"""Append-only change journal consumed by the sync pulls.

The journal is keyed by *profile* (the scope of a change, ADR 0006 §1), the lock
by the *owner* of that profile: all scopes of one owner share one lock.

``seq`` comes from a sequence, so it is allocated at INSERT time while rows
become visible at COMMIT time. If two transactions writing to one scope
interleave (T1 gets seq 7, T2 gets seq 8 and commits first), a pull between the
commits returns 8 and the client's cursor jumps over 7 for ever. Every
transaction that journals therefore takes the advisory lock of the scope's owner
*before* its first journal insert and holds it until commit
(:func:`lock_journal`): per owner, seq order equals commit order. Writers of
different owners never wait for each other. A batch that spans several owners
takes their locks in sorted order, so two such batches cannot deadlock.

The invariant is enforced, not conventional: :func:`record_change` raises
:class:`JournalLockError` unless the lock of the scope's owner is held by the
current transaction (tracked in ``session.info``).
"""

from __future__ import annotations

import uuid
from collections.abc import Collection
from typing import Any, Literal

from sqlalchemy import func, insert, literal, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import DoseEvent, Profile, SyncChange

Entity = Literal["profile", "medication", "schedule", "dose_event"]
# ``privacy`` is a medication whose privacy level changed; it never appears on the wire.
Op = Literal["upsert", "delete", "privacy"]

_INFO_KEY = "journal_owner_locks"


class JournalLockError(RuntimeError):
    """A journal write without the lock of the scope's owner: a bug, never user input."""


def held_owner_locks(session: AsyncSession) -> set[uuid.UUID]:
    """Owners whose journal lock the session's *current* transaction holds."""
    entry: tuple[Any, set[uuid.UUID]] | None = session.info.get(_INFO_KEY)
    if entry is None or entry[0] is not session.sync_session.get_transaction():
        return set()  # a commit or rollback released everything taken before
    return set(entry[1])


async def lock_journal(session: AsyncSession, owner_ids: Collection[uuid.UUID]) -> None:
    """Serialize journal writers of ``owner_ids`` until the transaction ends.

    Call it in the top-level transaction (a lock taken inside a SAVEPOINT is
    released when that savepoint rolls back) before any journal insert and
    before taking row locks, so all writers lock in the same order. Owners are
    locked in sorted order. Re-entrant within a transaction.
    """
    held = held_owner_locks(session)
    for owner_id in sorted(set(owner_ids)):
        key = func.hashtextextended(str(owner_id), 0)
        await session.execute(select(func.pg_advisory_xact_lock(key)))
        held.add(owner_id)
    # Read after the first statement: the transaction exists from then on.
    session.info[_INFO_KEY] = (session.sync_session.get_transaction(), held)


async def _require_owner_lock(session: AsyncSession, profile_id: uuid.UUID) -> None:
    owner_id = await session.scalar(select(Profile.owner_user_id).where(Profile.id == profile_id))
    if owner_id is None or owner_id not in held_owner_locks(session):
        raise JournalLockError("journal write without the lock of the scope's owner")


async def record_change(
    session: AsyncSession,
    profile_id: uuid.UUID,
    entity: Entity,
    entity_id: uuid.UUID,
    op: Op,
) -> None:
    """Journal one applied change into the profile's scope (after :func:`lock_journal`)."""
    await _require_owner_lock(session, profile_id)
    await session.execute(
        insert(SyncChange).values(profile_id=profile_id, entity=entity, entity_id=entity_id, op=op)
    )


async def record_changes(
    session: AsyncSession,
    profile_id: uuid.UUID,
    entity: Entity,
    entity_ids: list[uuid.UUID],
    op: Op,
) -> None:
    if not entity_ids:
        return
    await _require_owner_lock(session, profile_id)
    await session.execute(
        insert(SyncChange),
        [
            {"profile_id": profile_id, "entity": entity, "entity_id": eid, "op": op}
            for eid in entity_ids
        ],
    )


async def rejournal_dose_events(
    session: AsyncSession, profile_id: uuid.UUID, medication_id: uuid.UUID
) -> None:
    """Journal every dose event of a medication again (it became visible to relatives)."""
    await _require_owner_lock(session, profile_id)
    await session.execute(
        insert(SyncChange).from_select(
            ["profile_id", "entity", "entity_id", "op"],
            select(literal(profile_id), literal("dose_event"), DoseEvent.id, literal("upsert"))
            .where(DoseEvent.medication_id == medication_id)
            .order_by(DoseEvent.at, DoseEvent.id),
        )
    )
