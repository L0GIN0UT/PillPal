"""Redeeming a promo code (ADR 0018 section 4): one transaction, explicit outcomes.

Under the account's row lock (``FOR UPDATE``, the lock of ``app.admin.entitlements``: a grant and
a redeem of one account never interleave, and the erase job waits):

1. insert the redemption ``ON CONFLICT DO NOTHING``; a conflict means this account redeemed the
   code before: a replay, nothing is written, a revoked entitlement is never granted again;
2. the guarded ``UPDATE`` takes one activation only while the code has one left and is neither
   expired nor disabled; with no row the redemption is rolled back (a rejection);
3. insert the entitlement; the deferred foreign key of the redemption is checked at commit.

The caller counts a rejection as a failure. The code itself is never stored, logged or kept
longer than the digest computation.
"""

from __future__ import annotations

import enum
import uuid
from datetime import datetime, timedelta

from sqlalchemy import or_, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.entitlements import Entitlement
from app.db.models import User
from app.db.promo import PromoCode, PromoRedemption
from app.domain.promo import lookup_digest

SOURCE = "promo"


class RedeemOutcome(enum.Enum):
    REDEEMED = "redeemed"
    REPLAYED = "replayed"
    # Unknown, expired, exhausted, disabled or a bad alphabet: one answer for all of them.
    REJECTED = "rejected"
    ACCOUNT_GONE = "account_gone"


async def redeem_code(
    session: AsyncSession, user_id: uuid.UUID, promo_code: str, key: bytes, now: datetime
) -> RedeemOutcome:
    """Redeem ``promo_code`` for the account. Commits on ``REDEEMED``, rolls back otherwise."""
    digest = lookup_digest(key, promo_code)
    if digest is None:
        return RedeemOutcome.REJECTED
    user = await session.scalar(
        select(User)
        .where(User.id == user_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if user is None or user.pending_deletion:
        await session.rollback()
        return RedeemOutcome.ACCOUNT_GONE
    code_id = await session.scalar(select(PromoCode.id).where(PromoCode.code_digest == digest))
    if code_id is None:
        await session.rollback()
        return RedeemOutcome.REJECTED
    entitlement_id = uuid.uuid4()
    inserted = await session.execute(
        insert(PromoRedemption)
        .values(code_id=code_id, user_id=user_id, redeemed_at=now, entitlement_id=entitlement_id)
        .on_conflict_do_nothing()
        .returning(PromoRedemption.code_id)
    )
    if inserted.first() is None:
        await session.rollback()
        return RedeemOutcome.REPLAYED
    taken = await session.execute(
        update(PromoCode)
        .where(
            PromoCode.id == code_id,
            PromoCode.activations < PromoCode.max_activations,
            PromoCode.disabled_at.is_(None),
            or_(PromoCode.expires_at.is_(None), PromoCode.expires_at > now),
        )
        .values(activations=PromoCode.activations + 1)
        .returning(PromoCode.kind, PromoCode.grant_days)
    )
    row = taken.first()
    if row is None:
        await session.rollback()
        return RedeemOutcome.REJECTED
    kind, grant_days = row
    session.add(
        Entitlement(
            id=entitlement_id,
            user_id=user_id,
            kind=kind,
            source=SOURCE,
            source_ref=code_id,
            granted_at=now,
            expires_at=None if grant_days is None else now + timedelta(days=grant_days),
        )
    )
    await session.commit()
    return RedeemOutcome.REDEEMED
