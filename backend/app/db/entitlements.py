"""Entitlements and the admin audit (ADR 0018 sections 1 and 5; migrations 0018, 0019).

``entitlements`` is personal data of the account (kind, source, validity; no medical context) and
cascades with the user. ``admin_audit`` records what an operator did through ``python -m
app.admin``: the operator is a self-declared handle plus the OS user and host, the target is an
account id, never an e-mail. On erasure the row stays without the person (``target_user_id`` is
``ON DELETE SET NULL``; ``app.services.erasure`` also nulls ``object_id`` first).
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, ForeignKey, Index, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, sql_in
from app.db.models import NOW
from app.domain.entitlements import ENTITLEMENT_KINDS, ENTITLEMENT_SOURCES

AUDIT_ACTIONS = ("entitlement_grant", "entitlement_revoke", "promo_create", "promo_disable")
MAX_ACTOR_LENGTH = 64
MAX_OPERATOR_FIELD_LENGTH = 255


class Entitlement(Base):
    __tablename__ = "entitlements"
    __table_args__ = (
        CheckConstraint(sql_in("kind", ENTITLEMENT_KINDS), name="kind"),
        CheckConstraint(sql_in("source", ENTITLEMENT_SOURCES), name="source"),
        CheckConstraint("expires_at > granted_at", name="expires_after_granted"),
        Index("ix_entitlements_user_id_kind", "user_id", "kind"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    kind: Mapped[str] = mapped_column(Text)
    source: Mapped[str] = mapped_column(Text)
    # The originating purchase (5.10) or promo code (``promo_codes.id``, 5.4); no foreign key.
    source_ref: Mapped[uuid.UUID | None]
    granted_at: Mapped[datetime] = mapped_column(server_default=NOW)
    expires_at: Mapped[datetime | None]
    revoked_at: Mapped[datetime | None]


class AdminAudit(Base):
    __tablename__ = "admin_audit"
    __table_args__ = (
        CheckConstraint(
            f"char_length(actor) BETWEEN 1 AND {MAX_ACTOR_LENGTH} AND position('@' in actor) = 0 "
            "AND actor ~ '^[[:print:]]+$'",
            name="actor",
        ),
        CheckConstraint(sql_in("action", AUDIT_ACTIONS), name="action"),
        CheckConstraint(sql_in("kind", ENTITLEMENT_KINDS), name="kind"),
        CheckConstraint(
            f"(os_user IS NULL OR (char_length(os_user) <= {MAX_OPERATOR_FIELD_LENGTH} "
            "AND position('@' in os_user) = 0)) "
            f"AND (host IS NULL OR (char_length(host) <= {MAX_OPERATOR_FIELD_LENGTH} "
            "AND position('@' in host) = 0))",
            name="operator_fields",
        ),
        Index("ix_admin_audit_at", "at"),
        Index("ix_admin_audit_target_user_id", "target_user_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    at: Mapped[datetime] = mapped_column(server_default=NOW)
    actor: Mapped[str] = mapped_column(Text)
    action: Mapped[str] = mapped_column(Text)
    target_user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL")
    )
    # A promo code (its id, never the code), entitlement or purchase id; never a user id.
    object_id: Mapped[uuid.UUID | None]
    kind: Mapped[str | None] = mapped_column(Text)
    os_user: Mapped[str | None] = mapped_column(Text)
    host: Mapped[str | None] = mapped_column(Text)
