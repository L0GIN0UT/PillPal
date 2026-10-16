"""Relatives: profile grants and invites (ADR 0005, ADR 0009).

A *grant* gives another account a role on one profile; it is created only by
accepting an *invite*. Invariants live in PostgreSQL (migrations 0004, 0005):
one grant per (profile, grantee); the grantee is never the profile's owner
(also checked when ``profiles.owner_user_id`` changes); ``guardian`` only on
managed profiles; no new grant or role change on a tombstoned profile.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Literal, get_args

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    ForeignKey,
    Index,
    Integer,
    Text,
    UniqueConstraint,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, sql_in
from app.db.models import NOW, TimestampsMixin

# Roles a grant can carry; ``owner`` comes from ``profiles.owner_user_id``, never a grant.
GrantRole = Literal["viewer", "editor", "guardian"]
GRANT_ROLES: tuple[str, ...] = get_args(GrantRole)


class ProfileGrant(TimestampsMixin, Base):
    __tablename__ = "profile_grants"
    __table_args__ = (
        UniqueConstraint("profile_id", "grantee_user_id"),
        Index("ix_profile_grants_grantee_user_id", "grantee_user_id"),
        # The earliest co-guardian takes over a managed profile (owner decision D1).
        Index("ix_profile_grants_profile_id_role_created_at", "profile_id", "role", "created_at"),
        CheckConstraint(sql_in("role", GRANT_ROLES), name="role"),
        CheckConstraint("disclosure_version >= 1", name="disclosure_version"),
        CheckConstraint("granted_seq >= 0", name="granted_seq"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    profile_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("profiles.id", ondelete="CASCADE"))
    grantee_user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    role: Mapped[str] = mapped_column(Text)
    # The grantee's own choice: a relative may mute missed-dose alerts.
    notify_missed: Mapped[bool] = mapped_column(server_default=text("true"))
    # Version of the disclosure screen the owner confirmed when inviting (what the
    # relative will see): the Phase 3 record of the decision to disclose.
    disclosure_version: Mapped[int] = mapped_column(Integer)
    # Provenance only, deliberately no FK: invites are purged by retention.
    invite_id: Mapped[uuid.UUID | None]
    # Journal head of the profile when the grant was made (read under the owner's journal
    # lock): sync pull sends a projected role no narrowing or tombstone at or below it.
    granted_seq: Mapped[int] = mapped_column(BigInteger, server_default=text("0"))


class Invite(Base):
    """Single-use invite; only ``sha256(token)`` is stored (ADR 0009 §1)."""

    __tablename__ = "invites"
    __table_args__ = (
        Index(
            "ix_invites_profile_id_active",
            "profile_id",
            postgresql_where=text("consumed_at IS NULL AND revoked_at IS NULL"),
        ),
        Index("ix_invites_created_by_user_id", "created_by_user_id"),
        Index(
            "ix_invites_consumed_by_user_id",
            "consumed_by_user_id",
            postgresql_where=text("consumed_by_user_id IS NOT NULL"),
        ),
        CheckConstraint(sql_in("role", GRANT_ROLES), name="role"),
        CheckConstraint("disclosure_version >= 1", name="disclosure_version"),
        CheckConstraint("expires_at > created_at", name="expires_after_created"),
        CheckConstraint("NOT (consumed_at IS NOT NULL AND revoked_at IS NOT NULL)", name="one_end"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    profile_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("profiles.id", ondelete="CASCADE"))
    created_by_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE")
    )
    role: Mapped[str] = mapped_column(Text)
    disclosure_version: Mapped[int] = mapped_column(Integer)
    token_hash: Mapped[str] = mapped_column(Text, unique=True)
    created_at: Mapped[datetime] = mapped_column(server_default=NOW)
    expires_at: Mapped[datetime]
    consumed_at: Mapped[datetime | None]
    # Cleared by retention after ``INVITE_REPLAY_WINDOW_SECONDS`` (set NULL on user erasure).
    consumed_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL")
    )
    revoked_at: Mapped[datetime | None]
