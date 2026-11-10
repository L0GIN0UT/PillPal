"""Data exports: request, build state and the encrypted archive (ADR 0016 section 8).

The archive is encrypted ``bytea`` that lives at most ``EXPORT_TTL_HOURS`` and is nulled on the
single download or on expiry; the CHECKs keep it out of every other status. Rows cascade with the
user.

Revision ID: 0021_data_exports
Revises: 0020_promo_codes
Create Date: 2026-11-10
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0021_data_exports"
down_revision: str | None = "0020_promo_codes"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

NOW = sa.text("now()")
TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "data_exports",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("family_id", sa.Uuid(), nullable=False),
        sa.Column("status", sa.Text(), nullable=False),
        sa.Column("error_code", sa.Text(), nullable=True),
        sa.Column("requested_at", TS, server_default=NOW, nullable=False),
        sa.Column("lease_until", TS, nullable=True),
        sa.Column("ready_at", TS, nullable=True),
        sa.Column("expires_at", TS, nullable=True),
        sa.Column("size_bytes", sa.Integer(), nullable=True),
        sa.Column("archive", sa.LargeBinary(), nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_data_exports")),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_data_exports_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.CheckConstraint(
            "status IN ('queued', 'running', 'ready', 'downloaded', 'failed', 'expired')",
            name=op.f("ck_data_exports_status"),
        ),
        sa.CheckConstraint(
            "error_code IS NULL OR error_code IN ('export_too_large', 'export_build_failed')",
            name=op.f("ck_data_exports_error_code"),
        ),
        sa.CheckConstraint(
            "archive IS NULL OR status = 'ready'",
            name=op.f("ck_data_exports_archive_only_when_ready"),
        ),
    )
    op.create_index(
        op.f("ix_data_exports_user_id_requested_at"),
        "data_exports",
        ["user_id", "requested_at"],
        unique=False,
    )
    op.create_index(op.f("ix_data_exports_status"), "data_exports", ["status"], unique=False)


def downgrade() -> None:
    op.drop_index(op.f("ix_data_exports_status"), table_name="data_exports")
    op.drop_index(op.f("ix_data_exports_user_id_requested_at"), table_name="data_exports")
    op.drop_table("data_exports")
