"""The push outbox: enqueue in the caller's transaction, cancel, retention (ADR 0008 §6).

``enqueue`` writes one row per push token of the recipient, in the same transaction as the
event that causes the push (an accepted invite, a restored account, a missed-dose alert), so a
push exists exactly when its event committed. ``dedupe_key`` makes a replay of the event enqueue
nothing twice. Rows are delivered by ``app.services.push_delivery``,
which re-checks access at send time.

Only a ``PushPayload`` can be enqueued: ids and enums, no text.
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime

from sqlalchemy import select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import Profile
from app.db.push import PushOutbox, PushToken
from app.push.base import PushPayload

ACCESS_CHANGED = "access_changed"


@dataclass(frozen=True, slots=True)
class OutboxItem:
    """One push to queue for every token of ``recipient_user_id`` (see :func:`enqueue_many`)."""

    recipient_user_id: uuid.UUID
    payload: PushPayload
    ref: str
    subject_profile_id: uuid.UUID
    subject_medication_id: uuid.UUID | None = None


async def enqueue_many(session: AsyncSession, items: Sequence[OutboxItem], *, now: datetime) -> int:
    """Queue every item for every token of its recipient; returns the rows actually added.

    Two statements whatever the number of items (the missed-dose detector queues hundreds per
    batch): one read of the recipients' tokens, one multi-row insert. ``ref`` identifies the
    event (``{alert_id}``, ``{grant_id}:{restore_epoch}``); the dedupe key is
    ``{kind}:{ref}:{push_token_id}``, so a replayed event adds nothing. A recipient without a
    token gets nothing: the Family tab's banner still shows new and restored links (ADR 0008 §1).
    """
    if not items:
        return 0
    recipients = {item.recipient_user_id for item in items}
    token_rows = (
        await session.execute(
            select(PushToken.user_id, PushToken.id).where(PushToken.user_id.in_(recipients))
        )
    ).all()
    tokens: dict[uuid.UUID, list[uuid.UUID]] = {}
    for user_id, token_id in token_rows:
        tokens.setdefault(user_id, []).append(token_id)
    values = [
        {
            "push_token_id": token_id,
            "recipient_user_id": item.recipient_user_id,
            "subject_profile_id": item.subject_profile_id,
            "subject_medication_id": item.subject_medication_id,
            "kind": item.payload.t,
            "dedupe_key": f"{item.payload.t}:{item.ref}:{token_id}",
            "payload": item.payload.to_wire(),
            "next_attempt_at": now,
            "created_at": now,
        }
        for item in items
        for token_id in tokens.get(item.recipient_user_id, [])
    ]
    if not values:
        return 0
    stmt = (
        pg_insert(PushOutbox)
        .values(values)
        .on_conflict_do_nothing(index_elements=[PushOutbox.dedupe_key])
        .returning(PushOutbox.id)
    )
    return len((await session.execute(stmt)).all())


async def enqueue(
    session: AsyncSession,
    *,
    recipient_user_id: uuid.UUID,
    payload: PushPayload,
    ref: str,
    subject_profile_id: uuid.UUID,
    subject_medication_id: uuid.UUID | None = None,
    now: datetime,
) -> int:
    """Queue ``payload`` for every token of one recipient (:func:`enqueue_many` for one item)."""
    item = OutboxItem(recipient_user_id, payload, ref, subject_profile_id, subject_medication_id)
    return await enqueue_many(session, [item], now=now)


async def drop_pending_about_profiles_of(session: AsyncSession, owner_id: uuid.UUID) -> int:
    """Mark pending pushes about ``owner_id``'s profiles as dropped (a deletion request).

    The send-time check would drop them anyway; doing it in the request's own transaction
    means nothing about the account is left queued once the request commits.
    """
    subjects = select(Profile.id).where(Profile.owner_user_id == owner_id)
    result = await session.execute(
        update(PushOutbox)
        .where(PushOutbox.status == "pending", PushOutbox.subject_profile_id.in_(subjects))
        .values(status="dropped", last_error_code=ACCESS_CHANGED)
        .execution_options(synchronize_session=False)
    )
    return int(result.rowcount)  # type: ignore[attr-defined]
