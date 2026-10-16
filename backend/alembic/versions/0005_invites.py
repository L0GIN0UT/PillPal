"""Relatives: ``invites`` (ADR 0009 §1, §4).

An invite carries a client-generated id (a lost create response can be
retried) and ``sha256(token)`` of a 256-bit token; the token itself is never
stored. Single use: ``consumed_at`` / ``consumed_by_user_id`` or ``revoked_at``
(never both). The accepter's id is cleared by the retention job after the
replay window; ``ON DELETE SET NULL`` does the same when that account is erased.

The partial index serves the cap on active invites per profile. Trigger
``invites_guard`` (BEFORE INSERT and BEFORE UPDATE OF role) allows ``guardian``
only on managed profiles, like the grant it will become.

Revision ID: 0005_invites
Revises: 0004_profile_grants
Create Date: 2026-10-16
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0005_invites"
down_revision: str | None = "0004_profile_grants"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

NOW = sa.text("now()")
TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "invites",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("profile_id", sa.Uuid(), nullable=False),
        sa.Column("created_by_user_id", sa.Uuid(), nullable=False),
        sa.Column("role", sa.Text(), nullable=False),
        sa.Column("disclosure_version", sa.Integer(), nullable=False),
        sa.Column("token_hash", sa.Text(), nullable=False),
        sa.Column("created_at", TS, server_default=NOW, nullable=False),
        sa.Column("expires_at", TS, nullable=False),
        sa.Column("consumed_at", TS, nullable=True),
        sa.Column("consumed_by_user_id", sa.Uuid(), nullable=True),
        sa.Column("revoked_at", TS, nullable=True),
        sa.PrimaryKeyConstraint("id", name="pk_invites"),
        sa.ForeignKeyConstraint(
            ["profile_id"],
            ["profiles.id"],
            name="fk_invites_profile_id_profiles",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["created_by_user_id"],
            ["users.id"],
            name="fk_invites_created_by_user_id_users",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["consumed_by_user_id"],
            ["users.id"],
            name="fk_invites_consumed_by_user_id_users",
            ondelete="SET NULL",
        ),
        sa.UniqueConstraint("token_hash", name="uq_invites_token_hash"),
        sa.CheckConstraint("role IN ('viewer', 'editor', 'guardian')", name="ck_invites_role"),
        sa.CheckConstraint("disclosure_version >= 1", name="ck_invites_disclosure_version"),
        sa.CheckConstraint("expires_at > created_at", name="ck_invites_expires_after_created"),
        sa.CheckConstraint(
            "NOT (consumed_at IS NOT NULL AND revoked_at IS NOT NULL)", name="ck_invites_one_end"
        ),
    )
    op.create_index(
        "ix_invites_profile_id_active",
        "invites",
        ["profile_id"],
        postgresql_where=sa.text("consumed_at IS NULL AND revoked_at IS NULL"),
    )
    op.create_index("ix_invites_created_by_user_id", "invites", ["created_by_user_id"])
    op.create_index(
        "ix_invites_consumed_by_user_id",
        "invites",
        ["consumed_by_user_id"],
        postgresql_where=sa.text("consumed_by_user_id IS NOT NULL"),
    )
    op.execute(
        """
        CREATE FUNCTION invites_guard() RETURNS trigger
        LANGUAGE plpgsql AS $$
        BEGIN
            IF NEW.role = 'guardian' AND NOT EXISTS (
                SELECT 1 FROM profiles WHERE id = NEW.profile_id AND kind = 'managed'
            ) THEN
                RAISE EXCEPTION 'invites: guardian requires a managed profile'
                    USING ERRCODE = 'check_violation';
            END IF;
            RETURN NEW;
        END;
        $$
        """
    )
    op.execute(
        """
        CREATE TRIGGER invites_guard
        BEFORE INSERT OR UPDATE OF role ON invites
        FOR EACH ROW EXECUTE FUNCTION invites_guard()
        """
    )


def downgrade() -> None:
    # Open invite links stop working; granted links are not affected.
    op.drop_table("invites")
    op.execute("DROP FUNCTION IF EXISTS invites_guard()")
