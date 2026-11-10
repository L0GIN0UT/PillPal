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

import asyncio
import enum
import uuid
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.db.entitlements import Entitlement
from app.db.models import User
from app.db.purchases import Purchase
from app.domain.payments import PRODUCT_GRANTS
from app.observability import get_logger
from app.payments.base import InvalidPurchase, StoreUnavailable, VerifiedPurchase
from app.payments.registry import PaymentRegistry
from app.services.entitlements import account_token_for

SOURCE = "purchase"
# A conflicting row can vanish before it is read (its account was erased in between): one more try.
INSERT_ATTEMPTS = 2
_log = get_logger("pillpal.purchases")


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
    for _ in range(INSERT_ATTEMPTS):
        if await _insert_purchase(session, purchase_id, user_id, purchase, now):
            break
        owner = await session.scalar(
            select(Purchase.user_id).where(
                Purchase.store == purchase.store,
                Purchase.original_transaction_id == purchase.original_transaction_id,
            )
        )
        if owner is not None:
            await session.rollback()
            return ClaimOutcome.REPLAYED if owner == user_id else ClaimOutcome.CLAIMED_BY_OTHER
    else:
        await session.rollback()
        return ClaimOutcome.CLAIMED_BY_OTHER
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


async def _insert_purchase(
    session: AsyncSession,
    purchase_id: uuid.UUID,
    user_id: uuid.UUID,
    purchase: VerifiedPurchase,
    now: datetime,
) -> bool:
    """``True`` when the row is ours; ``False`` when ``(store, original id)`` already exists."""
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
    return inserted.first() is not None


async def verify_and_claim(
    session: AsyncSession,
    registry: PaymentRegistry,
    settings: Settings,
    user_id: uuid.UUID,
    store: str,
    proof: str,
    now: datetime,
) -> ClaimOutcome:
    """Verify ``proof`` for the account, then claim it.

    Raises ``InvalidPurchase`` (the proof is not a valid purchase of this account, or the region
    does not offer the store) or ``StoreUnavailable`` (a stub or unconfigured store). The proof is
    neither logged nor kept; only the fixed reason code is.
    """
    verifier = registry.get(store)
    token = account_token_for(settings, user_id)
    try:
        if verifier is None:
            raise InvalidPurchase("store_not_offered")
        if token is None:
            raise StoreUnavailable
        purchase = await asyncio.to_thread(verifier.verify, proof, account_token=token, now=now)
    except InvalidPurchase as exc:
        _log.info("purchase_rejected", store=store, reason=exc.reason)
        raise
    return await claim_purchase(session, user_id, purchase, now)
