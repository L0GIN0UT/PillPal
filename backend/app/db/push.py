"""Push delivery tables (ADR 0008): device tokens and the transactional outbox.

Invariants live in PostgreSQL (migrations 0010, 0011):

* a token belongs to one registered device (composite FK to ``devices``; deleting the
  device deletes the token) and has a provider-specific format, because the APNs token is
  placed in a URL path;
* ``(provider, token)`` is unique: a token moving to another account is reassigned;
* an outbox payload holds only the short keys of ``app.push.base.PushPayload`` with id or
  enum values, never text (``ck_push_outbox_payload_*``).
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    ForeignKey,
    ForeignKeyConstraint,
    Index,
    Integer,
    Text,
    UniqueConstraint,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, sql_in
from app.db.models import NOW, TimestampsMixin
from app.push.base import (
    APNS_TOKEN_PATTERN,
    MAX_TOKEN_LENGTH,
    OPAQUE_TOKEN_PATTERN,
    PAYLOAD_KEYS,
    PUSH_KINDS,
    PUSH_PROVIDERS,
)

APNS_ENVIRONMENTS = ("sandbox", "production")
OUTBOX_STATUSES = ("pending", "sent", "dropped")

UUID_PATTERN = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"


class PushToken(TimestampsMixin, Base):
    __tablename__ = "push_tokens"
    __table_args__ = (
        ForeignKeyConstraint(
            ["user_id", "device_id"],
            ["devices.user_id", "devices.device_id"],
            ondelete="CASCADE",
            name="fk_push_tokens_user_id_devices",
        ),
        UniqueConstraint("user_id", "device_id"),
        UniqueConstraint("provider", "token"),
        CheckConstraint(sql_in("provider", PUSH_PROVIDERS), name="provider"),
        CheckConstraint(
            f"char_length(token) BETWEEN 1 AND {MAX_TOKEN_LENGTH}", name="token_length"
        ),
        CheckConstraint(
            f"(provider = 'apns' AND token ~ '{APNS_TOKEN_PATTERN}') "
            f"OR (provider <> 'apns' AND token ~ '{OPAQUE_TOKEN_PATTERN}')",
            name="token_format",
        ),
        CheckConstraint(
            f"(provider = 'apns') = (apns_environment IS NOT NULL) "
            f"AND (apns_environment IS NULL OR {sql_in('apns_environment', APNS_ENVIRONMENTS)})",
            name="apns_environment",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    user_id: Mapped[uuid.UUID]
    device_id: Mapped[str] = mapped_column(Text)
    provider: Mapped[str] = mapped_column(Text)
    token: Mapped[str] = mapped_column(Text)
    apns_environment: Mapped[str | None] = mapped_column(Text)
    last_success_at: Mapped[datetime | None]


def _payload_value_checks() -> str:
    uuid_keys = " AND ".join(
        f"(payload->>'{key}' IS NULL OR payload->>'{key}' ~ '{UUID_PATTERN}')"
        for key in ("a", "p", "m", "g")
    )
    return (
        f"{uuid_keys} AND (payload->>'s' IS NULL OR payload->>'s' = 'u') "
        "AND payload->>'v' = '1' AND payload->>'t' = kind"
    )


class PushOutbox(Base):
    __tablename__ = "push_outbox"
    __table_args__ = (
        UniqueConstraint("dedupe_key"),
        CheckConstraint(sql_in("kind", PUSH_KINDS), name="kind"),
        CheckConstraint(sql_in("status", OUTBOX_STATUSES), name="status"),
        CheckConstraint("attempts >= 0", name="attempts_non_negative"),
        CheckConstraint("(status = 'sent') = (sent_at IS NOT NULL)", name="sent_at"),
        CheckConstraint(
            "jsonb_typeof(payload) = 'object' AND (payload - "
            f"ARRAY[{', '.join(repr(key) for key in PAYLOAD_KEYS)}]) = '{{}}'::jsonb",
            name="payload_keys",
        ),
        CheckConstraint(_payload_value_checks(), name="payload_values"),
        Index(
            "ix_push_outbox_pending",
            "next_attempt_at",
            postgresql_where=text("status = 'pending'"),
        ),
        Index("ix_push_outbox_push_token_id", "push_token_id"),
        Index("ix_push_outbox_recipient_user_id", "recipient_user_id"),
        Index("ix_push_outbox_subject_profile_id", "subject_profile_id"),
        Index("ix_push_outbox_subject_medication_id", "subject_medication_id"),
        Index("ix_push_outbox_created_at", "created_at"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    push_token_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("push_tokens.id", ondelete="CASCADE")
    )
    recipient_user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    subject_profile_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("profiles.id", ondelete="CASCADE")
    )
    subject_medication_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("medications.id", ondelete="CASCADE")
    )
    kind: Mapped[str] = mapped_column(Text)
    dedupe_key: Mapped[str] = mapped_column(Text)
    payload: Mapped[dict[str, Any]] = mapped_column(JSONB)
    status: Mapped[str] = mapped_column(Text, server_default=text("'pending'"))
    attempts: Mapped[int] = mapped_column(Integer, server_default=text("0"))
    next_attempt_at: Mapped[datetime] = mapped_column(server_default=NOW)
    created_at: Mapped[datetime] = mapped_column(server_default=NOW)
    sent_at: Mapped[datetime | None]
    # A provider error code, ``access_changed``, ``stale``, ``provider_disabled``: never a token.
    last_error_code: Mapped[str | None] = mapped_column(Text)
