"""Purchases of an account (ADR 0018 section 6, milestone 5.10).

``purchases`` holds one row per verified store purchase under the store's stable identifier
(``original_transaction_id``); ``UNIQUE (store, original_transaction_id)`` deduplicates, so one
purchase belongs to one account. The signed transaction or token is never stored. Personal data:
cascades with the user, exported and erased with the account.

Revision ID: 0023_purchases
Revises: 0022_auth_identities
Create Date: 2026-11-10
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0023_purchases"
down_revision: str | None = "0022_auth_identities"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "purchases",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("store", sa.Text(), nullable=False),
        sa.Column("product_id", sa.Text(), nullable=False),
        sa.Column("original_transaction_id", sa.Text(), nullable=False),
        sa.Column("environment", sa.Text(), nullable=False),
        sa.Column("purchased_at", TS, nullable=False),
        sa.Column("verified_at", TS, nullable=False),
        sa.Column("revoked_at", TS, nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_purchases")),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_purchases_user_id_users"), ondelete="CASCADE"
        ),
        sa.UniqueConstraint(
            "store",
            "original_transaction_id",
            name=op.f("uq_purchases_store_original_transaction_id"),
        ),
        sa.CheckConstraint(
            "store IN ('app_store', 'rustore', 'google_play')", name=op.f("ck_purchases_store")
        ),
        sa.CheckConstraint(
            "environment IN ('production', 'sandbox')", name=op.f("ck_purchases_environment")
        ),
        sa.CheckConstraint(
            "char_length(product_id) BETWEEN 1 AND 255", name=op.f("ck_purchases_product_id")
        ),
        sa.CheckConstraint(
            "char_length(original_transaction_id) BETWEEN 1 AND 255",
            name=op.f("ck_purchases_original_transaction_id"),
        ),
    )
    op.create_index(op.f("ix_purchases_user_id"), "purchases", ["user_id"], unique=False)


def downgrade() -> None:
    op.drop_table("purchases")
