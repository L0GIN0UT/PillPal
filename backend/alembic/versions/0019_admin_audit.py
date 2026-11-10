"""Admin audit: what an operator did through ``python -m app.admin`` (ADR 0018 section 5).

The actor is a self-declared handle (1..64 printable characters, never an e-mail), recorded with
the OS user and the host, which the operator cannot declare away. The target is an account id
(``ON DELETE SET NULL``: on erasure the row stays without the person); ``object_id`` is an
entitlement, promo or purchase id, never a user id.

Revision ID: 0019_admin_audit
Revises: 0018_entitlements
Create Date: 2026-11-10
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0019_admin_audit"
down_revision: str | None = "0018_entitlements"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

NOW = sa.text("now()")
TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "admin_audit",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("at", TS, server_default=NOW, nullable=False),
        sa.Column("actor", sa.Text(), nullable=False),
        sa.Column("action", sa.Text(), nullable=False),
        sa.Column("target_user_id", sa.Uuid(), nullable=True),
        sa.Column("object_id", sa.Uuid(), nullable=True),
        sa.Column("kind", sa.Text(), nullable=True),
        sa.Column("os_user", sa.Text(), nullable=True),
        sa.Column("host", sa.Text(), nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_admin_audit")),
        sa.ForeignKeyConstraint(
            ["target_user_id"],
            ["users.id"],
            name=op.f("fk_admin_audit_target_user_id_users"),
            ondelete="SET NULL",
        ),
        sa.CheckConstraint(
            "char_length(actor) BETWEEN 1 AND 64 AND position('@' in actor) = 0 "
            "AND actor ~ '^[[:print:]]+$'",
            name=op.f("ck_admin_audit_actor"),
        ),
        sa.CheckConstraint(
            "action IN ('entitlement_grant', 'entitlement_revoke')",
            name=op.f("ck_admin_audit_action"),
        ),
        sa.CheckConstraint(
            "kind IN ('ads_removed', 'limits_lifted')", name=op.f("ck_admin_audit_kind")
        ),
        sa.CheckConstraint(
            "(os_user IS NULL OR (char_length(os_user) <= 255 AND position('@' in os_user) = 0)) "
            "AND (host IS NULL OR (char_length(host) <= 255 AND position('@' in host) = 0))",
            name=op.f("ck_admin_audit_operator_fields"),
        ),
    )
    op.create_index(op.f("ix_admin_audit_at"), "admin_audit", ["at"], unique=False)
    op.create_index(
        op.f("ix_admin_audit_target_user_id"), "admin_audit", ["target_user_id"], unique=False
    )


def downgrade() -> None:
    op.drop_index(op.f("ix_admin_audit_target_user_id"), table_name="admin_audit")
    op.drop_index(op.f("ix_admin_audit_at"), table_name="admin_audit")
    op.drop_table("admin_audit")
