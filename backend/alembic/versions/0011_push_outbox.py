"""Push: ``push_outbox``, the transactional outbox (ADR 0008 §6).

Rows are written in the transaction of the event that causes them (an accepted invite, a
restored account, from 3.5 a missed-dose alert) and delivered at least once by the worker.
``dedupe_key`` is UNIQUE so a replayed event enqueues nothing twice.

The payload is the privacy boundary: a CHECK allows only the short keys of
``PushPayload`` (``v t a p m g s``) and, for each, an id or enum value, so no free text
(a medication name, a dose) can be stored even by a buggy writer. Access is re-checked at
send time from the ``subject_*`` columns (FK ``ON DELETE CASCADE``: purging a profile
removes its pending pushes).

Revision ID: 0011_push_outbox
Revises: 0010_push_tokens
Create Date: 2026-10-17
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = "0011_push_outbox"
down_revision: str | None = "0010_push_tokens"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

NOW = sa.text("now()")
TS = sa.DateTime(timezone=True)
UUID_RE = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
PAYLOAD_VALUES = (
    " AND ".join(
        f"(payload->>'{key}' IS NULL OR payload->>'{key}' ~ '{UUID_RE}')"
        for key in ("a", "p", "m", "g")
    )
    + " AND (payload->>'s' IS NULL OR payload->>'s' = 'u')"
    + " AND payload->>'v' = '1' AND payload->>'t' = kind"
)


def upgrade() -> None:
    op.create_table(
        "push_outbox",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("push_token_id", sa.Uuid(), nullable=False),
        sa.Column("recipient_user_id", sa.Uuid(), nullable=False),
        sa.Column("subject_profile_id", sa.Uuid(), nullable=True),
        sa.Column("subject_medication_id", sa.Uuid(), nullable=True),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("dedupe_key", sa.Text(), nullable=False),
        sa.Column("payload", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("status", sa.Text(), server_default=sa.text("'pending'"), nullable=False),
        sa.Column("attempts", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.Column("next_attempt_at", TS, server_default=NOW, nullable=False),
        sa.Column("created_at", TS, server_default=NOW, nullable=False),
        sa.Column("sent_at", TS, nullable=True),
        sa.Column("last_error_code", sa.Text(), nullable=True),
        sa.PrimaryKeyConstraint("id", name="pk_push_outbox"),
        sa.ForeignKeyConstraint(
            ["push_token_id"],
            ["push_tokens.id"],
            name="fk_push_outbox_push_token_id_push_tokens",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["recipient_user_id"],
            ["users.id"],
            name="fk_push_outbox_recipient_user_id_users",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["subject_profile_id"],
            ["profiles.id"],
            name="fk_push_outbox_subject_profile_id_profiles",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["subject_medication_id"],
            ["medications.id"],
            name="fk_push_outbox_subject_medication_id_medications",
            ondelete="CASCADE",
        ),
        sa.UniqueConstraint("dedupe_key", name="uq_push_outbox_dedupe_key"),
        sa.CheckConstraint(
            "kind IN ('missed', 'resolved', 'link_accepted', 'link_restored')",
            name="ck_push_outbox_kind",
        ),
        sa.CheckConstraint(
            "status IN ('pending', 'sent', 'dropped')", name="ck_push_outbox_status"
        ),
        sa.CheckConstraint("attempts >= 0", name="ck_push_outbox_attempts_non_negative"),
        sa.CheckConstraint(
            "(status = 'sent') = (sent_at IS NOT NULL)", name="ck_push_outbox_sent_at"
        ),
        sa.CheckConstraint(
            "jsonb_typeof(payload) = 'object' AND (payload - "
            "ARRAY['v', 't', 'a', 'p', 'm', 'g', 's']) = '{}'::jsonb",
            name="ck_push_outbox_payload_keys",
        ),
        sa.CheckConstraint(PAYLOAD_VALUES, name="ck_push_outbox_payload_values"),
    )
    op.create_index(
        "ix_push_outbox_pending",
        "push_outbox",
        ["next_attempt_at"],
        postgresql_where=sa.text("status = 'pending'"),
    )
    op.create_index("ix_push_outbox_push_token_id", "push_outbox", ["push_token_id"])
    op.create_index("ix_push_outbox_recipient_user_id", "push_outbox", ["recipient_user_id"])
    op.create_index("ix_push_outbox_subject_profile_id", "push_outbox", ["subject_profile_id"])
    op.create_index(
        "ix_push_outbox_subject_medication_id", "push_outbox", ["subject_medication_id"]
    )
    op.create_index("ix_push_outbox_created_at", "push_outbox", ["created_at"])


def downgrade() -> None:
    op.drop_table("push_outbox")
