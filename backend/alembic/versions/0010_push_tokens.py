"""Push: ``push_tokens`` (ADR 0008 §1).

One token per registered device (composite FK to ``devices``, so deleting a device or an
account deletes its token), unique per ``(provider, token)`` so a token that moves to
another account is reassigned rather than duplicated. The token has a provider-specific
format in a CHECK: the APNs token is put into a URL path, so it must be lower-case hex.
(PostgreSQL limits regex repetition counts to 255, so the 4096-character limit of FCM and
RuStore tokens is a separate length CHECK.)

Revision ID: 0010_push_tokens
Revises: 0009_profile_archive
Create Date: 2026-10-17
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0010_push_tokens"
down_revision: str | None = "0009_profile_archive"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

NOW = sa.text("now()")
TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "push_tokens",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("device_id", sa.Text(), nullable=False),
        sa.Column("provider", sa.Text(), nullable=False),
        sa.Column("token", sa.Text(), nullable=False),
        sa.Column("apns_environment", sa.Text(), nullable=True),
        sa.Column("last_success_at", TS, nullable=True),
        sa.Column("created_at", TS, server_default=NOW, nullable=False),
        sa.Column("updated_at", TS, server_default=NOW, nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_push_tokens"),
        sa.ForeignKeyConstraint(
            ["user_id", "device_id"],
            ["devices.user_id", "devices.device_id"],
            name="fk_push_tokens_user_id_devices",
            ondelete="CASCADE",
        ),
        sa.UniqueConstraint("user_id", "device_id", name="uq_push_tokens_user_id_device_id"),
        sa.UniqueConstraint("provider", "token", name="uq_push_tokens_provider_token"),
        sa.CheckConstraint(
            "provider IN ('fcm', 'apns', 'rustore')", name="ck_push_tokens_provider"
        ),
        sa.CheckConstraint(
            "char_length(token) BETWEEN 1 AND 4096", name="ck_push_tokens_token_length"
        ),
        sa.CheckConstraint(
            "(provider = 'apns' AND token ~ '^[0-9a-f]{64,200}$') "
            "OR (provider <> 'apns' AND token ~ '^[A-Za-z0-9_:-]+$')",
            name="ck_push_tokens_token_format",
        ),
        sa.CheckConstraint(
            "(provider = 'apns') = (apns_environment IS NOT NULL) "
            "AND (apns_environment IS NULL OR apns_environment IN ('sandbox', 'production'))",
            name="ck_push_tokens_apns_environment",
        ),
    )


def downgrade() -> None:
    op.drop_table("push_tokens")
