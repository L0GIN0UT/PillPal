"""ORM models (TZ §4.1). Invariants live in the schema, not only in code.

Every mutable sync entity (profiles, medications, schedules) carries:

* ``version`` - incremented by the server on every applied change;
* ``client_updated_at`` + ``updated_by_device`` - the last-write-wins key;
* ``deleted_at`` - tombstone. Tombstones keep ids and the conflict key but no
  content (names, notes, rules): CHECK constraints require content on live
  rows and its absence on tombstones.

``dose_events`` is append-only; a trigger created by the migration rejects
UPDATE and DELETE (DELETE only passes inside an account purge transaction).
Deleting an account removes every row it owns.
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

from app.db.base import Base, sql_in

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


_in = sql_in


def _live_only(condition: str) -> str:
    """A content rule that binds live rows only (tombstones carry no content)."""
    return f"deleted_at IS NOT NULL OR ({condition})"


def _erased_when_deleted(columns: tuple[str, ...]) -> str:
    return f"deleted_at IS NULL OR ({' AND '.join(f'{c} IS NULL' for c in columns)})"


# Content erased from tombstones (privacy: no medical data outlives a delete).
PROFILE_CONTENT = ("display_name",)
MEDICATION_CONTENT = (
    "name",
    "form",
    "strength_text",
    "notes",
    "stock_count",
    "stock_unit",
    "low_stock_days",
    "stock_set_at",
)
SCHEDULE_CONTENT = ("rule",)


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
        # Deleted accounts are erased, so the address can register again.
        Index("uq_users_email", text("lower(email)"), unique=True),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(Text)
    password_hash: Mapped[str] = mapped_column(Text)
    region: Mapped[str] = mapped_column(Text)
    locale: Mapped[str] = mapped_column(Text, server_default=text("'en'"))
    email_verified_at: Mapped[datetime | None]
    # Access tokens issued (``iat``) before this instant are rejected.
    password_changed_at: Mapped[datetime | None]


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
        CheckConstraint(
            _live_only("display_name IS NOT NULL AND char_length(display_name) BETWEEN 1 AND 100"),
            name="display_name",
        ),
        CheckConstraint(_erased_when_deleted(PROFILE_CONTENT), name="tombstone_erased"),
        CheckConstraint("char_length(timezone) BETWEEN 1 AND 64", name="timezone"),
        CheckConstraint("missed_alert_minutes BETWEEN 5 AND 720", name="missed_alert_minutes"),
        CheckConstraint("version >= 1", name="version_positive"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    owner_user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    kind: Mapped[str] = mapped_column(Text)
    display_name: Mapped[str | None] = mapped_column(Text)
    timezone: Mapped[str] = mapped_column(Text)
    # Missed-dose alerts for relatives: minutes after the due time, and an off switch.
    missed_alert_minutes: Mapped[int] = mapped_column(Integer, server_default=text("30"))
    missed_alerts_enabled: Mapped[bool] = mapped_column(server_default=text("true"))


class Medication(SyncEntityMixin, Base):
    __tablename__ = "medications"
    __table_args__ = (
        Index("ix_medications_profile_id", "profile_id"),
        CheckConstraint(
            _live_only("name IS NOT NULL AND char_length(name) BETWEEN 1 AND 200"), name="name"
        ),
        CheckConstraint(_erased_when_deleted(MEDICATION_CONTENT), name="tombstone_erased"),
        CheckConstraint(_in("tz_mode", TZ_MODES), name="tz_mode"),
        CheckConstraint("(tz_mode = 'fixed') = (fixed_tz IS NOT NULL)", name="fixed_tz"),
        CheckConstraint(_in("privacy", PRIVACY_LEVELS), name="privacy"),
        CheckConstraint("stock_count IS NULL OR stock_count >= 0", name="stock_count"),
        # A stock baseline only exists with a counted stock (ADR 0004).
        CheckConstraint("stock_set_at IS NULL OR stock_count IS NOT NULL", name="stock_set_at"),
        CheckConstraint(
            "low_stock_days IS NULL OR low_stock_days BETWEEN 0 AND 365", name="low_stock_days"
        ),
        CheckConstraint("version >= 1", name="version_positive"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    profile_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("profiles.id", ondelete="CASCADE"))
    name: Mapped[str | None] = mapped_column(Text)
    form: Mapped[str | None] = mapped_column(Text)
    strength_text: Mapped[str | None] = mapped_column(Text)
    notes: Mapped[str | None] = mapped_column(Text)
    tz_mode: Mapped[str] = mapped_column(Text, server_default=text("'local'"))
    fixed_tz: Mapped[str | None] = mapped_column(Text)
    stock_count: Mapped[Decimal | None] = mapped_column(Numeric(12, 3))
    stock_unit: Mapped[str | None] = mapped_column(Text)
    low_stock_days: Mapped[int | None] = mapped_column(Integer)
    # When ``stock_count`` was entered; clients subtract the doses taken after
    # it (docs/adr/0004-stock-tracking.md), so the count is never decremented.
    stock_set_at: Mapped[datetime | None]
    privacy: Mapped[str] = mapped_column(Text, server_default=text("'shared'"))


class Schedule(SyncEntityMixin, Base):
    __tablename__ = "schedules"
    __table_args__ = (
        Index("ix_schedules_medication_id", "medication_id"),
        CheckConstraint(
            _live_only(
                "rule IS NOT NULL AND jsonb_typeof(rule) = 'object' "
                "AND rule ? 'v' AND rule ? 'kind'"
            ),
            name="rule_shape",
        ),
        CheckConstraint(_erased_when_deleted(SCHEDULE_CONTENT), name="tombstone_erased"),
        CheckConstraint("version >= 1", name="version_positive"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    medication_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("medications.id", ondelete="CASCADE")
    )
    # none_as_null: an erased rule is SQL NULL, not the JSON value ``null``.
    rule: Mapped[dict[str, Any] | None] = mapped_column(JSONB(none_as_null=True))


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
        # Migration 0002 adds both as NOT VALID: rows written before it may be
        # ``snoozed`` without ``snooze_until``; every new row is checked.
        CheckConstraint("(type = 'snoozed') = (snooze_until IS NOT NULL)", name="snooze_until"),
        CheckConstraint(
            "snooze_until IS NULL OR "
            "(snooze_until > at AND snooze_until <= at + interval '24 hours')",
            name="snooze_until_window",
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
    # When a snoozed occurrence is due again (ADR 0001 §7); only for ``snoozed``.
    snooze_until: Mapped[datetime | None]


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
