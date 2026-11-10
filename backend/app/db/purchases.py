"""Purchases of an account (ADR 0018 section 6; migration 0023).

One row per verified store purchase: which product, from which store, under which stable
purchase identifier (``original_transaction_id``, the store's own id mapped into one generic
column). The signed transaction or token it was verified from is never stored. Personal data of
the account: exported as rows, erased with it. ``UNIQUE (store, original_transaction_id)`` is
the deduplication: a purchase belongs to one account.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, ForeignKey, Index, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, sql_in
from app.domain.payments import ENVIRONMENTS, STORES

MAX_IDENTIFIER_LENGTH = 255


class Purchase(Base):
    __tablename__ = "purchases"
    __table_args__ = (
        UniqueConstraint("store", "original_transaction_id"),
        CheckConstraint(sql_in("store", STORES), name="store"),
        CheckConstraint(sql_in("environment", ENVIRONMENTS), name="environment"),
        CheckConstraint(
            f"char_length(product_id) BETWEEN 1 AND {MAX_IDENTIFIER_LENGTH}", name="product_id"
        ),
        CheckConstraint(
            f"char_length(original_transaction_id) BETWEEN 1 AND {MAX_IDENTIFIER_LENGTH}",
            name="original_transaction_id",
        ),
        Index("ix_purchases_user_id", "user_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    store: Mapped[str] = mapped_column(Text)
    product_id: Mapped[str] = mapped_column(Text)
    original_transaction_id: Mapped[str] = mapped_column(Text)
    environment: Mapped[str] = mapped_column(Text)
    purchased_at: Mapped[datetime]
    verified_at: Mapped[datetime]
    # Set by a refund or revocation (App Store Server Notifications are a later slice).
    revoked_at: Mapped[datetime | None]
