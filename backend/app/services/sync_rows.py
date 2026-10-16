"""Journal rows for a pull: what a relative may read, in SQL (ADR 0006 §2, §4).

A relative with the privacy projection (``editor``, ``viewer``) never *reads* the
journal rows of a ``hidden`` medication or of its schedules and dose events:
they are filtered here, in the query, so they cannot advance the cursor either
(the cursor is the newest row read). Otherwise cursor movement alone would tell a
relative that something hidden happened. One exception: ``privacy`` rows of a
medication are read, because the narrowing delete is built from them
(``sync_pull``). The owner and guardians read everything.
"""

from __future__ import annotations

import uuid
from collections.abc import Collection, Mapping
from typing import Any

from sqlalchemy import (
    BigInteger,
    Boolean,
    ColumnElement,
    Select,
    Uuid,
    and_,
    column,
    false,
    func,
    or_,
    select,
    true,
    values,
)
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased

from app.db.models import DoseEvent, Medication, Schedule, SyncChange


def _filtered[*Row](stmt: Select[*Row], projected: ColumnElement[bool] | None) -> Select[*Row]:
    """Restrict a select over ``SyncChange`` to rows a projected relative may read.

    ``projected`` says per row whether the filter applies (``None``: always).
    """
    med, sched, event, parent = (
        aliased(Medication),
        aliased(Schedule),
        aliased(DoseEvent),
        aliased(Medication),
    )
    stmt = (
        stmt.outerjoin(med, and_(SyncChange.entity == "medication", med.id == SyncChange.entity_id))
        .outerjoin(sched, and_(SyncChange.entity == "schedule", sched.id == SyncChange.entity_id))
        .outerjoin(event, and_(SyncChange.entity == "dose_event", event.id == SyncChange.entity_id))
        .outerjoin(parent, parent.id == func.coalesce(sched.medication_id, event.medication_id))
    )
    hidden = or_(
        and_(
            SyncChange.entity == "medication", SyncChange.op != "privacy", med.privacy == "hidden"
        ),
        and_(SyncChange.entity.in_(("schedule", "dose_event")), parent.privacy == "hidden"),
    )
    readable = func.coalesce(hidden, false()).is_(False)
    return stmt.where(readable if projected is None else or_(projected.is_(False), readable))


async def read_rows(
    session: AsyncSession,
    cursors: Mapping[uuid.UUID, int],
    projected: Collection[uuid.UUID],
    limit: int,
) -> list[Any]:
    """Up to ``limit + 1`` readable rows after each scope's own cursor, in seq order.

    Per scope a LATERAL subquery takes at most ``limit + 1`` rows through the
    ``(profile_id, seq)`` index, so a page costs O(scopes x limit), not a scan of
    every scope's tail. The extra row is the probe for ``has_more``.
    """
    if not cursors:
        return []
    wanted = values(
        column("profile_id", Uuid),
        column("after_seq", BigInteger),
        column("projected", Boolean),
        name="wanted",
    ).data([(pid, after, pid in projected) for pid, after in cursors.items()])
    inner = _filtered(
        select(
            SyncChange.seq,
            SyncChange.profile_id,
            SyncChange.entity,
            SyncChange.entity_id,
            SyncChange.op,
            SyncChange.created_at,
        ).where(SyncChange.profile_id == wanted.c.profile_id, SyncChange.seq > wanted.c.after_seq),
        wanted.c.projected,
    )
    per_scope = inner.order_by(SyncChange.seq).limit(limit + 1).lateral("rows")
    stmt = (
        select(*per_scope.c)
        .select_from(wanted)
        .join(per_scope, true())
        .order_by(per_scope.c.seq)
        .limit(limit + 1)
    )
    return list((await session.execute(stmt)).all())


async def readable_heads(
    session: AsyncSession, profile_ids: Collection[uuid.UUID]
) -> dict[uuid.UUID, int]:
    """Newest readable seq of each projected scope: where a backfill from zero ends."""
    if not profile_ids:
        return {}
    stmt = _filtered(
        select(SyncChange.profile_id, func.max(SyncChange.seq)).where(
            SyncChange.profile_id.in_(list(profile_ids))
        ),
        None,
    ).group_by(SyncChange.profile_id)
    return {pid: int(head) for pid, head in await session.execute(stmt)}


async def creation_seqs(
    session: AsyncSession, medications: Collection[tuple[uuid.UUID, uuid.UUID]]
) -> dict[tuple[uuid.UUID, uuid.UUID], int]:
    """First journal seq of each (scope, medication): when the medication appeared."""
    if not medications:
        return {}
    stmt = (
        select(SyncChange.profile_id, SyncChange.entity_id, func.min(SyncChange.seq))
        .where(
            SyncChange.entity == "medication",
            SyncChange.profile_id.in_({pid for pid, _ in medications}),
            SyncChange.entity_id.in_({mid for _, mid in medications}),
        )
        .group_by(SyncChange.profile_id, SyncChange.entity_id)
    )
    return {(pid, mid): int(seq) for pid, mid, seq in await session.execute(stmt)}
