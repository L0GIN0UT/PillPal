"""ORM models (TZ §4.1). Invariants live in the schema, not only in code.

Every mutable sync entity (profiles, medications, schedules) carries:

* ``version`` - incremented by the server on every applied change;
* ``client_updated_at`` + ``updated_by_device`` - the last-write-wins key;
* ``deleted_at`` - tombstone (rows are never physically deleted by the API).

``dose_events`` is append-only; a trigger created by the migration rejects
UPDATE and DELETE.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal
from typing import Any

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    Text,
    UniqueConstraint,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base

NOW = text("now()")

REGIONS = ("ru", "eu")
LOCALES = ("ru", "en")
PROFILE_KINDS = ("self", "managed")
TZ_MODES = ("local", "fixed")
PRIVACY_LEVELS = ("shared", "anonymous", "hidden")
DOSE_EVENT_TYPES = ("taken", "skipped", "snoozed", "undo")
EMAIL_CODE_PURPOSES = ("verify_email", "password_reset")
SYNC_ENTITIES = ("profile", "medication", "schedule", "dose_event")
SYNC_OPS = ("upsert", "delete")


def _in(column: str, values: tuple[str, ...]) -> str:
    return f"{column} IN ({', '.join(repr(v) for v in values)})"


class TimestampsMixin:
    created_at: Mapped[datetime] = mapped_column(server_default=NOW)
    updated_at: Mapped[datetime] = mapped_column(server_default=NOW)


class SyncEntityMixin(TimestampsMixin):
    version: Mapped[int] = mapped_column(Integer, server_default=text("1"))
    client_updated_at: Mapped[datetime]
    updated_by_device: Mapped[str] = mapped_column(Text, server_default=text("''"))
    deleted_at: Mapped[datetime | None]


class User(TimestampsMixin, Base):
    __tablename__ = "users"
    __table_args__ = (
        CheckConstraint(_in("region", REGIONS), name="region"),
        CheckConstraint(_in("locale", LOCALES), name="locale"),
        CheckConstraint("char_length(email) BETWEEN 3 AND 320", name="email_length"),
        # E-mail is unique among live accounts only, so a deleted account's
        # address can register again.
        Index(
            "uq_users_email_active",
            text("lower(email)"),
            unique=True,
            postgresql_where=text("deleted_at IS NULL"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(Text)
    password_hash: Mapped[str] = mapped_column(Text)
    region: Mapped[str] = mapped_column(Text)
    locale: Mapped[str] = mapped_column(Text, server_default=text("'en'"))
    email_verified_at: Mapped[datetime | None]
    deleted_at: Mapped[datetime | None]


class Device(Base):
    __tablename__ = "devices"
    __table_args__ = (
        UniqueConstraint("user_id", "device_id"),
        CheckConstraint("char_length(device_id) BETWEEN 1 AND 128", name="device_id_length"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    device_id: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(server_default=NOW)
    last_seen_at: Mapped[datetime] = mapped_column(server_default=NOW)


class RefreshToken(Base):
    __tablename__ = "refresh_tokens"
    __table_args__ = (
        Index("ix_refresh_tokens_user_id", "user_id"),
        Index("ix_refresh_tokens_family_id", "family_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    family_id: Mapped[uuid.UUID]
    token_hash: Mapped[str] = mapped_column(Text, unique=True)
    device_id: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(server_default=NOW)
    expires_at: Mapped[datetime]
    used_at: Mapped[datetime | None]
    revoked_at: Mapped[datetime | None]


class EmailCode(Base):
    __tablename__ = "email_codes"
    __table_args__ = (
        Index("ix_email_codes_user_id_purpose", "user_id", "purpose"),
        CheckConstraint(_in("purpose", EMAIL_CODE_PURPOSES), name="purpose"),
        CheckConstraint("attempts >= 0", name="attempts_non_negative"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    purpose: Mapped[str] = mapped_column(Text)
    code_hash: Mapped[str] = mapped_column(Text)
    attempts: Mapped[int] = mapped_column(Integer, server_default=text("0"))
    created_at: Mapped[datetime] = mapped_column(server_default=NOW)
    expires_at: Mapped[datetime]
    consumed_at: Mapped[datetime | None]


class Profile(SyncEntityMixin, Base):
    __tablename__ = "profiles"
    __table_args__ = (
        Index("ix_profiles_owner_user_id", "owner_user_id"),
        Index(
            "uq_profiles_one_self_per_user",
            "owner_user_id",
            unique=True,
            postgresql_where=text("kind = 'self'"),
        ),
        CheckConstraint(_in("kind", PROFILE_KINDS), name="kind"),
        CheckConstraint("char_length(display_name) BETWEEN 1 AND 100", name="display_name"),
        CheckConstraint("char_length(timezone) BETWEEN 1 AND 64", name="timezone"),
        CheckConstraint("version >= 1", name="version_positive"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    owner_user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    kind: Mapped[str] = mapped_column(Text)
    display_name: Mapped[str] = mapped_column(Text)
    timezone: Mapped[str] = mapped_column(Text)


class Medication(SyncEntityMixin, Base):
    __tablename__ = "medications"
    __table_args__ = (
        Index("ix_medications_profile_id", "profile_id"),
        CheckConstraint("char_length(name) BETWEEN 1 AND 200", name="name"),
        CheckConstraint(_in("tz_mode", TZ_MODES), name="tz_mode"),
        CheckConstraint("(tz_mode = 'fixed') = (fixed_tz IS NOT NULL)", name="fixed_tz"),
        CheckConstraint(_in("privacy", PRIVACY_LEVELS), name="privacy"),
        CheckConstraint("stock_count IS NULL OR stock_count >= 0", name="stock_count"),
        CheckConstraint(
            "low_stock_days IS NULL OR low_stock_days BETWEEN 0 AND 365", name="low_stock_days"
        ),
        CheckConstraint("version >= 1", name="version_positive"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    profile_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("profiles.id", ondelete="CASCADE"))
    name: Mapped[str] = mapped_column(Text)
    form: Mapped[str | None] = mapped_column(Text)
    strength_text: Mapped[str | None] = mapped_column(Text)
    notes: Mapped[str | None] = mapped_column(Text)
    tz_mode: Mapped[str] = mapped_column(Text, server_default=text("'local'"))
    fixed_tz: Mapped[str | None] = mapped_column(Text)
    stock_count: Mapped[Decimal | None] = mapped_column(Numeric(12, 3))
    stock_unit: Mapped[str | None] = mapped_column(Text)
    low_stock_days: Mapped[int | None] = mapped_column(Integer)
    privacy: Mapped[str] = mapped_column(Text, server_default=text("'shared'"))


class Schedule(SyncEntityMixin, Base):
    __tablename__ = "schedules"
    __table_args__ = (
        Index("ix_schedules_medication_id", "medication_id"),
        CheckConstraint(
            "jsonb_typeof(rule) = 'object' AND rule ? 'v' AND rule ? 'kind'", name="rule_shape"
        ),
        CheckConstraint("version >= 1", name="version_positive"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    medication_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("medications.id", ondelete="CASCADE")
    )
    rule: Mapped[dict[str, Any]] = mapped_column(JSONB)


class DoseEvent(Base):
    __tablename__ = "dose_events"
    __table_args__ = (
        Index("ix_dose_events_profile_id_occurrence_key", "profile_id", "occurrence_key"),
        Index("ix_dose_events_medication_id_at", "medication_id", "at"),
        Index(
            "ix_dose_events_target_event_id",
            "target_event_id",
            postgresql_where=text("target_event_id IS NOT NULL"),
        ),
        CheckConstraint(_in("type", DOSE_EVENT_TYPES), name="type"),
        CheckConstraint("(type = 'undo') = (target_event_id IS NOT NULL)", name="undo_target"),
        CheckConstraint("note IS NULL OR char_length(note) <= 1000", name="note_length"),
        CheckConstraint(
            "occurrence_key IS NULL OR char_length(occurrence_key) <= 64", name="occurrence_key"
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    profile_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("profiles.id", ondelete="CASCADE"))
    medication_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("medications.id", ondelete="CASCADE")
    )
    occurrence_key: Mapped[str | None] = mapped_column(Text)
    type: Mapped[str] = mapped_column(Text)
    target_event_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("dose_events.id"))
    at: Mapped[datetime]
    recorded_at: Mapped[datetime] = mapped_column(server_default=NOW)
    device_id: Mapped[str | None] = mapped_column(Text)
    note: Mapped[str | None] = mapped_column(Text)


class SyncChange(Base):
    __tablename__ = "sync_changes"
    __table_args__ = (
        Index("ix_sync_changes_user_id_seq", "user_id", "seq"),
        CheckConstraint(_in("entity", SYNC_ENTITIES), name="entity"),
        CheckConstraint(_in("op", SYNC_OPS), name="op"),
    )

    seq: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    entity: Mapped[str] = mapped_column(Text)
    entity_id: Mapped[uuid.UUID]
    op: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(server_default=NOW)
