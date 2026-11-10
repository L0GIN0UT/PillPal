"""Sign-in identities (ADR 0017 section 2).

``auth_identities`` ties a provider's stable subject to an account. It cascades with the user, is
personal data (exported with the subject, never the encrypted token) and is erased with the
account. ``users`` is unchanged: an OAuth-only account stores an unusable sentinel in
``password_hash``.

Revision ID: 0022_auth_identities
Revises: 0021_data_exports
Create Date: 2026-11-10
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0022_auth_identities"
down_revision: str | None = "0021_data_exports"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "auth_identities",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("provider", sa.Text(), nullable=False),
        sa.Column("subject", sa.Text(), nullable=False),
        sa.Column("email_at_link", sa.Text(), nullable=True),
        sa.Column("created_at", TS, server_default=sa.text("now()"), nullable=False),
        sa.Column("last_used_at", TS, nullable=True),
        sa.Column("provider_refresh_token_enc", sa.LargeBinary(), nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_auth_identities")),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_auth_identities_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.UniqueConstraint(
            "provider", "subject", name=op.f("uq_auth_identities_provider_subject")
        ),
        sa.CheckConstraint(
            "provider IN ('apple', 'google', 'vk_id', 'yandex_id')",
            name=op.f("ck_auth_identities_provider"),
        ),
        sa.CheckConstraint(
            "char_length(subject) BETWEEN 1 AND 255", name=op.f("ck_auth_identities_subject")
        ),
    )
    op.create_index(op.f("ix_auth_identities_user_id"), "auth_identities", ["user_id"])


def downgrade() -> None:
    op.drop_table("auth_identities")
