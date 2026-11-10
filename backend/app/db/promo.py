"""Promo codes and their redemptions (ADR 0018 section 3; migration 0020).

``promo_codes`` is a system table: a campaign label and the keyed digest of the code, never the
code. ``promo_redemptions`` says which account redeemed which code, so it is personal data of the
account: it cascades with the user, is exported and is erased with the account.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, ForeignKey, Index, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, sql_in
from app.db.models import NOW
from app.domain.entitlements import ENTITLEMENT_KINDS

MAX_LABEL_LENGTH = 64
MAX_GRANT_DAYS = 3650


class PromoCode(Base):
    __tablename__ = "promo_codes"
    __table_args__ = (
        CheckConstraint("code_digest ~ '^[0-9a-f]{64}$'", name="code_digest"),
        CheckConstraint(f"char_length(label) BETWEEN 1 AND {MAX_LABEL_LENGTH}", name="label"),
        CheckConstraint(sql_in("kind", ENTITLEMENT_KINDS), name="kind"),
        CheckConstraint(
            f"grant_days IS NULL OR grant_days BETWEEN 1 AND {MAX_GRANT_DAYS}", name="grant_days"
        ),
        CheckConstraint("max_activations >= 1", name="max_activations"),
        CheckConstraint("activations BETWEEN 0 AND max_activations", name="activations"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    # HMAC-SHA256 of the normalised code, lower-case hex; the lookup value.
    code_digest: Mapped[str] = mapped_column(Text, unique=True)
    # A campaign name; it must hold no personal data.
    label: Mapped[str] = mapped_column(Text)
    kind: Mapped[str] = mapped_column(Text)
    # The entitlement lasts this many days from the redemption; ``None``: it does not expire.
    grant_days: Mapped[int | None]
    max_activations: Mapped[int]
    activations: Mapped[int] = mapped_column(server_default="0")
    expires_at: Mapped[datetime | None]
    disabled_at: Mapped[datetime | None]
    created_at: Mapped[datetime] = mapped_column(server_default=NOW)


class PromoRedemption(Base):
    __tablename__ = "promo_redemptions"
    __table_args__ = (Index("ix_promo_redemptions_user_id", "user_id"),)

    code_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("promo_codes.id"), primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    redeemed_at: Mapped[datetime] = mapped_column(server_default=NOW)
    # Inserted in the same transaction, after the redemption row: the check waits for the commit.
    entitlement_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("entitlements.id", deferrable=True, initially="DEFERRED")
    )
