"""Consent records (Phase 5.2a): which text of which kind an account accepted, and when.

Invariants live in PostgreSQL (migration 0017): a closed set of kinds and sources, a bounded
version, ``withdrawn_at`` never before ``accepted_at``, and at most one *active* record per
``(user, kind, version)`` (partial unique index), so a replayed accept is one row. Rows are
server-generated, not sync entities, and are erased with the account.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, ForeignKey, Index, Integer, Text, text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, sql_in
from app.db.models import NOW
from app.domain.consents import CONSENT_KINDS, CONSENT_SOURCES, MAX_CONSENT_VERSION


class Consent(Base):
    __tablename__ = "consents"
    __table_args__ = (
        CheckConstraint(sql_in("kind", CONSENT_KINDS), name="kind"),
        CheckConstraint(sql_in("source", CONSENT_SOURCES), name="source"),
        CheckConstraint(f"version BETWEEN 1 AND {MAX_CONSENT_VERSION}", name="version"),
        CheckConstraint("withdrawn_at IS NULL OR withdrawn_at >= accepted_at", name="withdrawn_at"),
        Index(
            "uq_consents_active",
            "user_id",
            "kind",
            "version",
            unique=True,
            postgresql_where=text("withdrawn_at IS NULL"),
        ),
        Index("ix_consents_user_id_kind", "user_id", "kind"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    kind: Mapped[str] = mapped_column(Text)
    version: Mapped[int] = mapped_column(Integer)
    source: Mapped[str] = mapped_column(Text)
    accepted_at: Mapped[datetime] = mapped_column(server_default=NOW)
    withdrawn_at: Mapped[datetime | None]
