"""Entitlements: what an account has earned (ADR 0018 section 1).

One row per grant (purchase, promo code or admin grant), per account; relatives and co-guardians
have their own accounts and rows. Revocation sets ``revoked_at``, rows are not deleted. The rows
cascade with the user. The ``source_ref`` has no foreign key: the purchase and redemption tables
come in later revisions and the reference is informational.

Revision ID: 0018_entitlements
Revises: 0017_consents
Create Date: 2026-11-10
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0018_entitlements"
down_revision: str | None = "0017_consents"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

NOW = sa.text("now()")
TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "entitlements",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("source", sa.Text(), nullable=False),
        sa.Column("source_ref", sa.Uuid(), nullable=True),
        sa.Column("granted_at", TS, server_default=NOW, nullable=False),
        sa.Column("expires_at", TS, nullable=True),
        sa.Column("revoked_at", TS, nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_entitlements")),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_entitlements_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.CheckConstraint(
            "kind IN ('ads_removed', 'limits_lifted')", name=op.f("ck_entitlements_kind")
        ),
        sa.CheckConstraint(
            "source IN ('purchase', 'promo', 'admin_grant')", name=op.f("ck_entitlements_source")
        ),
        sa.CheckConstraint(
            "expires_at > granted_at", name=op.f("ck_entitlements_expires_after_granted")
        ),
    )
    op.create_index(
        op.f("ix_entitlements_user_id_kind"), "entitlements", ["user_id", "kind"], unique=False
    )


def downgrade() -> None:
    op.drop_index(op.f("ix_entitlements_user_id_kind"), table_name="entitlements")
    op.drop_table("entitlements")
