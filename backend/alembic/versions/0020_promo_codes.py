"""Promo codes and their redemptions (ADR 0018 section 3).

``promo_codes`` holds the keyed digest of each code (never the code) and the limits of the
campaign; ``promo_redemptions`` records which account redeemed which code and cascades with the
user. ``entitlement_id`` is a deferred foreign key: the redemption row is inserted first (the
conflict decides a replay) and the entitlement second, in the same transaction.

``admin_audit.action`` gains ``promo_create`` and ``promo_disable``. The downgrade deletes the
audit rows with those actions first, otherwise the narrower CHECK could not be restored.

Revision ID: 0020_promo_codes
Revises: 0019_admin_audit
Create Date: 2026-11-10
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0020_promo_codes"
down_revision: str | None = "0019_admin_audit"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

NOW = sa.text("now()")
TS = sa.DateTime(timezone=True)
OLD_ACTIONS = "action IN ('entitlement_grant', 'entitlement_revoke')"
NEW_ACTIONS = (
    "action IN ('entitlement_grant', 'entitlement_revoke', 'promo_create', 'promo_disable')"
)


def upgrade() -> None:
    op.create_table(
        "promo_codes",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("code_digest", sa.Text(), nullable=False),
        sa.Column("label", sa.Text(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("grant_days", sa.Integer(), nullable=True),
        sa.Column("max_activations", sa.Integer(), nullable=False),
        sa.Column("activations", sa.Integer(), server_default="0", nullable=False),
        sa.Column("expires_at", TS, nullable=True),
        sa.Column("disabled_at", TS, nullable=True),
        sa.Column("created_at", TS, server_default=NOW, nullable=False),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_promo_codes")),
        sa.UniqueConstraint("code_digest", name=op.f("uq_promo_codes_code_digest")),
        sa.CheckConstraint(
            "code_digest ~ '^[0-9a-f]{64}$'", name=op.f("ck_promo_codes_code_digest")
        ),
        sa.CheckConstraint(
            "char_length(label) BETWEEN 1 AND 64", name=op.f("ck_promo_codes_label")
        ),
        sa.CheckConstraint(
            "kind IN ('ads_removed', 'limits_lifted')", name=op.f("ck_promo_codes_kind")
        ),
        sa.CheckConstraint(
            "grant_days IS NULL OR grant_days BETWEEN 1 AND 3650",
            name=op.f("ck_promo_codes_grant_days"),
        ),
        sa.CheckConstraint("max_activations >= 1", name=op.f("ck_promo_codes_max_activations")),
        sa.CheckConstraint(
            "activations BETWEEN 0 AND max_activations", name=op.f("ck_promo_codes_activations")
        ),
    )
    op.create_table(
        "promo_redemptions",
        sa.Column("code_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("redeemed_at", TS, server_default=NOW, nullable=False),
        sa.Column("entitlement_id", sa.Uuid(), nullable=False),
        sa.PrimaryKeyConstraint("code_id", "user_id", name=op.f("pk_promo_redemptions")),
        sa.ForeignKeyConstraint(
            ["code_id"], ["promo_codes.id"], name=op.f("fk_promo_redemptions_code_id_promo_codes")
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_promo_redemptions_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["entitlement_id"],
            ["entitlements.id"],
            name=op.f("fk_promo_redemptions_entitlement_id_entitlements"),
            deferrable=True,
            initially="DEFERRED",
        ),
    )
    op.create_index(
        op.f("ix_promo_redemptions_user_id"), "promo_redemptions", ["user_id"], unique=False
    )
    op.drop_constraint(op.f("ck_admin_audit_action"), "admin_audit", type_="check")
    op.create_check_constraint(op.f("ck_admin_audit_action"), "admin_audit", NEW_ACTIONS)


def downgrade() -> None:
    op.execute("DELETE FROM admin_audit WHERE action IN ('promo_create', 'promo_disable')")
    op.drop_constraint(op.f("ck_admin_audit_action"), "admin_audit", type_="check")
    op.create_check_constraint(op.f("ck_admin_audit_action"), "admin_audit", OLD_ACTIONS)
    op.drop_index(op.f("ix_promo_redemptions_user_id"), table_name="promo_redemptions")
    op.drop_table("promo_redemptions")
    op.drop_table("promo_codes")
