"""Relatives: ``profile_grants`` with guard triggers (ADR 0005 §1, §3).

A grant gives another account ``viewer``, ``editor`` or ``guardian`` on one
profile. The invariants are enforced by the database, not only by the API:

* UNIQUE (profile, grantee); index on the grantee and on (profile, role,
  created_at) for "the earliest co-guardian" (owner decision D1);
* trigger ``profile_grants_guard`` (BEFORE INSERT and BEFORE UPDATE OF role):
  the grantee is not the profile's owner, ``guardian`` only on managed
  profiles, nothing on a tombstoned profile. It fires on INSERT and role
  changes only, so ``notify_missed`` can always be changed (also on a profile
  that was deleted or later archived);
* trigger ``profiles_owner_change_guard`` (BEFORE UPDATE OF owner_user_id):
  a profile never moves to an owner who holds a grant on it.

The guard reads the profile ``FOR SHARE``: a concurrent tombstone either
commits first (the grant is refused) or waits for the grant's transaction.

Revision ID: 0004_profile_grants
Revises: 0003_medication_stock_set_at
Create Date: 2026-10-16
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0004_profile_grants"
down_revision: str | None = "0003_medication_stock_set_at"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

NOW = sa.text("now()")
TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "profile_grants",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("profile_id", sa.Uuid(), nullable=False),
        sa.Column("grantee_user_id", sa.Uuid(), nullable=False),
        sa.Column("role", sa.Text(), nullable=False),
        sa.Column("notify_missed", sa.Boolean(), server_default=sa.text("true"), nullable=False),
        sa.Column("disclosure_version", sa.Integer(), nullable=False),
        sa.Column("invite_id", sa.Uuid(), nullable=True),
        sa.Column("created_at", TS, server_default=NOW, nullable=False),
        sa.Column("updated_at", TS, server_default=NOW, nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_profile_grants"),
        sa.ForeignKeyConstraint(
            ["profile_id"],
            ["profiles.id"],
            name="fk_profile_grants_profile_id_profiles",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["grantee_user_id"],
            ["users.id"],
            name="fk_profile_grants_grantee_user_id_users",
            ondelete="CASCADE",
        ),
        sa.UniqueConstraint(
            "profile_id", "grantee_user_id", name="uq_profile_grants_profile_id_grantee_user_id"
        ),
        sa.CheckConstraint(
            "role IN ('viewer', 'editor', 'guardian')", name="ck_profile_grants_role"
        ),
        sa.CheckConstraint("disclosure_version >= 1", name="ck_profile_grants_disclosure_version"),
    )
    op.create_index("ix_profile_grants_grantee_user_id", "profile_grants", ["grantee_user_id"])
    op.create_index(
        "ix_profile_grants_profile_id_role_created_at",
        "profile_grants",
        ["profile_id", "role", "created_at"],
    )
    op.execute(
        """
        CREATE FUNCTION profile_grants_guard() RETURNS trigger
        LANGUAGE plpgsql AS $$
        DECLARE
            target profiles%ROWTYPE;
        BEGIN
            SELECT * INTO target FROM profiles WHERE id = NEW.profile_id FOR SHARE;
            IF NOT FOUND THEN
                RETURN NEW;  -- the foreign key reports the missing profile
            END IF;
            IF target.owner_user_id = NEW.grantee_user_id THEN
                RAISE EXCEPTION 'profile_grants: grantee is the owner of the profile'
                    USING ERRCODE = 'check_violation';
            END IF;
            IF NEW.role = 'guardian' AND target.kind <> 'managed' THEN
                RAISE EXCEPTION 'profile_grants: guardian requires a managed profile'
                    USING ERRCODE = 'check_violation';
            END IF;
            IF target.deleted_at IS NOT NULL THEN
                RAISE EXCEPTION 'profile_grants: profile is deleted'
                    USING ERRCODE = 'check_violation';
            END IF;
            RETURN NEW;
        END;
        $$
        """
    )
    op.execute(
        """
        CREATE TRIGGER profile_grants_guard
        BEFORE INSERT OR UPDATE OF role ON profile_grants
        FOR EACH ROW EXECUTE FUNCTION profile_grants_guard()
        """
    )
    op.execute(
        """
        CREATE FUNCTION profiles_owner_change_guard() RETURNS trigger
        LANGUAGE plpgsql AS $$
        BEGIN
            IF EXISTS (
                SELECT 1 FROM profile_grants
                WHERE profile_id = NEW.id AND grantee_user_id = NEW.owner_user_id
            ) THEN
                RAISE EXCEPTION 'profile_grants: grantee is the owner of the profile'
                    USING ERRCODE = 'check_violation';
            END IF;
            RETURN NEW;
        END;
        $$
        """
    )
    op.execute(
        """
        CREATE TRIGGER profiles_owner_change_guard
        BEFORE UPDATE OF owner_user_id ON profiles
        FOR EACH ROW WHEN (OLD.owner_user_id IS DISTINCT FROM NEW.owner_user_id)
        EXECUTE FUNCTION profiles_owner_change_guard()
        """
    )


def downgrade() -> None:
    # Links are dropped: relatives lose access, owners keep their data.
    op.execute("DROP TRIGGER IF EXISTS profiles_owner_change_guard ON profiles")
    op.execute("DROP FUNCTION IF EXISTS profiles_owner_change_guard()")
    op.drop_table("profile_grants")
    op.execute("DROP FUNCTION IF EXISTS profile_grants_guard()")
