"""Consent records: ``consents`` (Phase 5.2a, ``docs/phase5-plan.md``).

One row per accepted (kind, version) of an account. Kinds and sources are closed sets in CHECKs;
at most one active (not withdrawn) row per ``(user_id, kind, version)`` so a replayed accept is
one row; deleting the user deletes the rows (erasure, owner decision Q4).

Revision ID: 0017_consents
Revises: 0016_med_catalog_ref_index
Create Date: 2026-11-10
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0017_consents"
down_revision: str | None = "0016_med_catalog_ref_index"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "consents",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("source", sa.Text(), nullable=False),
        sa.Column("accepted_at", TS, server_default=sa.text("now()"), nullable=False),
        sa.Column("withdrawn_at", TS, nullable=True),
        sa.PrimaryKeyConstraint("id", name="pk_consents"),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name="fk_consents_user_id_users", ondelete="CASCADE"
        ),
        sa.CheckConstraint(
            "kind IN ('health_data', 'terms', 'privacy', 'catalog_contribution')",
            name="ck_consents_kind",
        ),
        sa.CheckConstraint(
            "source IN ('registration', 'in_app', 'oauth_signup', 'medication_link')",
            name="ck_consents_source",
        ),
        sa.CheckConstraint("version BETWEEN 1 AND 1000", name="ck_consents_version"),
        sa.CheckConstraint(
            "withdrawn_at IS NULL OR withdrawn_at >= accepted_at", name="ck_consents_withdrawn_at"
        ),
    )
    op.create_index(
        "uq_consents_active",
        "consents",
        ["user_id", "kind", "version"],
        unique=True,
        postgresql_where=sa.text("withdrawn_at IS NULL"),
    )
    op.create_index("ix_consents_user_id_kind", "consents", ["user_id", "kind"])


def downgrade() -> None:
    op.drop_table("consents")
