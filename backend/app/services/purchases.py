"""Claiming a verified purchase for an account (ADR 0018 section 6): one transaction.

Under the account's row lock (``FOR UPDATE``, the lock of ``grant_entitlement`` and the promo
redeem: the grant paths of one account never interleave, and the erase job waits):

1. insert the purchase ``ON CONFLICT (store, original_transaction_id) DO NOTHING``. The unique
   constraint, not a prior read, decides who owns a purchase, so two accounts claiming the same one
   at once cannot both win;
2. on a conflict the existing row says whose it is: this account's own is a replay (nothing is
   written, a revoked entitlement is never granted again), another account's is refused;
3. otherwise insert one entitlement per kind the product grants, sourced to the purchase.

The proof (the signed transaction) never reaches this module: only the verified facts do.
"""

from __future__ import annotations

import enum
import uuid
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.entitlements import Entitlement
from app.db.models import User
from app.db.purchases import Purchase
from app.domain.payments import PRODUCT_GRANTS
from app.payments.base import VerifiedPurchase

SOURCE = "purchase"


class ClaimOutcome(enum.Enum):
    CREATED = "created"
    REPLAYED = "replayed"
    # The purchase is held by another account: it never moves without an operator.
    CLAIMED_BY_OTHER = "claimed_by_other"
    ACCOUNT_GONE = "account_gone"


async def claim_purchase(
    session: AsyncSession, user_id: uuid.UUID, purchase: VerifiedPurchase, now: datetime
) -> ClaimOutcome:
    """Record ``purchase`` for the account and grant what its product grants.

    Commits on ``CREATED``, rolls back otherwise.
    """
    user = await session.scalar(
        select(User)
        .where(User.id == user_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if user is None or user.pending_deletion:
        await session.rollback()
        return ClaimOutcome.ACCOUNT_GONE
    purchase_id = uuid.uuid4()
    inserted = await session.execute(
        insert(Purchase)
        .values(
            id=purchase_id,
            user_id=user_id,
            store=purchase.store,
            product_id=purchase.product_id,
            original_transaction_id=purchase.original_transaction_id,
            environment=purchase.environment,
            purchased_at=purchase.purchased_at,
            verified_at=now,
        )
        .on_conflict_do_nothing(index_elements=["store", "original_transaction_id"])
        .returning(Purchase.id)
    )
    if inserted.first() is None:
        owner = await session.scalar(
            select(Purchase.user_id).where(
                Purchase.store == purchase.store,
                Purchase.original_transaction_id == purchase.original_transaction_id,
            )
        )
        await session.rollback()
        return ClaimOutcome.REPLAYED if owner == user_id else ClaimOutcome.CLAIMED_BY_OTHER
    for kind in PRODUCT_GRANTS[purchase.product_kind]:
        session.add(
            Entitlement(
                id=uuid.uuid4(),
                user_id=user_id,
                kind=kind,
                source=SOURCE,
                source_ref=purchase_id,
                granted_at=now,
            )
        )
    await session.commit()
    return ClaimOutcome.CREATED
