"""The catalog-contribution consent ledger (Phase 5.2b, ADR 0016 section 4).

A medication write that grants the contribution consent (``gtin_link_shared=true`` with a
version, full access only: ``resolve_consent`` never grants to an editor) records an active
``catalog_contribution`` / ``medication_link`` row for the writer in the same transaction. It adds
no journal entry. Withdrawal stamps the records and resets the links of the profiles the user
owns through the journaled reset, so every device sees it in its next pull. Only a profile's
owner can grant (owner decision 2026-11-10), so the ledger user is the owner and the reset is
exact.

Nothing here is logged: the ledger holds no medical data, and the links are opaque ids.
"""

from __future__ import annotations

import uuid
from collections.abc import Collection, Mapping
from datetime import datetime
from typing import Any

from sqlalchemy import func, select, text, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.consents import Consent
from app.db.models import Medication, Profile
from app.domain.consents import CONTRIBUTION_KIND
from app.errors import unauthorized
from app.services.changes import lock_journal
from app.services.medication_consent import reset_consent_in_profiles
from app.services.users import lock_user


def granted_version(before: Medication | None, written: Mapping[str, Any]) -> int | None:
    """The consent version a write grants, or ``None`` when it grants nothing.

    ``written`` is the output of ``with_consent``. An echo of a consent that is already stored
    keeps its ``consented_at``, so only a new grant (or a re-grant for another pair) differs.
    """
    version: int | None = written.get("gtin_link_consent_version")
    if not written.get("gtin_link_shared") or version is None:
        return None
    if before is None or not before.gtin_link_shared:
        return version
    if before.gtin_link_consented_at != written.get("gtin_link_consented_at"):
        return version
    return None


async def record_grant(
    session: AsyncSession, user_id: uuid.UUID, version: int | None, now: datetime
) -> None:
    """Insert the active record for ``version`` unless the user already has one.

    ``ON CONFLICT DO NOTHING`` on the partial unique index makes concurrent writers (a second
    device, a replay) land on one row without taking a lock.
    """
    if version is None:
        return
    await session.execute(
        insert(Consent)
        .values(
            id=uuid.uuid4(),
            user_id=user_id,
            kind=CONTRIBUTION_KIND,
            version=version,
            source="medication_link",
            accepted_at=now,
        )
        .on_conflict_do_nothing(
            index_elements=["user_id", "kind", "version"], index_where=text("withdrawn_at IS NULL")
        )
    )


async def withdraw_contribution(session: AsyncSession, user_id: uuid.UUID, now: datetime) -> int:
    """Withdraw the contribution consent; returns how many links were reset. The caller commits.

    Lock order as in ``request_deletion``: the user row, then the journal. Links of profiles the
    user does not own are not theirs to reset (they belong to the owner's own consent).
    """
    user = await lock_user(session, user_id)
    if user is None or user.pending_deletion:
        raise unauthorized()
    await lock_journal(session, [user_id])
    await stamp_withdrawn(session, user_id, (CONTRIBUTION_KIND,), now)
    owned = (
        await session.scalars(select(Profile.id).where(Profile.owner_user_id == user_id))
    ).all()
    return await reset_consent_in_profiles(session, owned)


async def stamp_withdrawn(
    session: AsyncSession, user_id: uuid.UUID, kinds: Collection[str], now: datetime
) -> None:
    """Set ``withdrawn_at`` on the user's active records of ``kinds``.

    greatest(): an injected clock may trail ``accepted_at`` (CHECK ``withdrawn_at >= accepted_at``).
    """
    await session.execute(
        update(Consent)
        .where(Consent.user_id == user_id, Consent.kind.in_(kinds), Consent.withdrawn_at.is_(None))
        .values(withdrawn_at=func.greatest(now, Consent.accepted_at))
        .execution_options(synchronize_session=False)
    )


async def latest_withdrawal(session: AsyncSession, user_id: uuid.UUID) -> datetime | None:
    """When the user last withdrew the contribution consent (a deletion request counts)."""
    return await session.scalar(
        select(func.max(Consent.withdrawn_at)).where(
            Consent.user_id == user_id, Consent.kind == CONTRIBUTION_KIND
        )
    )
