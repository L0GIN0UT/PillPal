"""Managed-profile archive (owner decision D1, ADR 0005 §5): columns, CHECKs, guards.

``archived_at`` / ``archive_reason`` are set together, only on managed profiles
(``owner_pending_deletion`` while the owner can still restore, ``owner_erased`` after
the hard erase), and ``archive_purge_after`` exists exactly for ``owner_erased``.
They are server-controlled: no API schema accepts them.

``profile_grants_guard`` and ``invites_guard`` are replaced by versions that also refuse
an archived profile (no new grant, no role change, no new invite): an archive is
read-only for everyone. ``notify_missed`` updates stay unguarded, as before.

Downgrade restores the previous guard functions and is refused while a profile is
archived (dropping the columns would make it writable again).

Revision ID: 0009_profile_archive
Revises: 0008_user_deletion_grace
Create Date: 2026-10-17
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0009_profile_archive"
down_revision: str | None = "0008_user_deletion_grace"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

TS = sa.DateTime(timezone=True)

# Bodies of 0004 / 0005, restored on downgrade.
_GRANTS_GUARD_BEFORE = """
CREATE OR REPLACE FUNCTION profile_grants_guard() RETURNS trigger
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

_GRANTS_GUARD_AFTER = _GRANTS_GUARD_BEFORE.replace(
    """    RETURN NEW;
END;
$$""",
    """    IF target.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'profile_grants: profile is archived'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$""",
)
# str.replace is silent when the anchor text drifts: fail the migration instead of shipping
# a guard without the archive check.
assert _GRANTS_GUARD_AFTER != _GRANTS_GUARD_BEFORE  # noqa: S101 - module-level guard, not test code

_INVITES_GUARD_BEFORE = """
CREATE OR REPLACE FUNCTION invites_guard() RETURNS trigger
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

_INVITES_GUARD_AFTER = """
CREATE OR REPLACE FUNCTION invites_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.role = 'guardian' AND NOT EXISTS (
        SELECT 1 FROM profiles WHERE id = NEW.profile_id AND kind = 'managed'
    ) THEN
        RAISE EXCEPTION 'invites: guardian requires a managed profile'
            USING ERRCODE = 'check_violation';
    END IF;
    IF EXISTS (
        SELECT 1 FROM profiles WHERE id = NEW.profile_id AND archived_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'invites: profile is archived' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$
"""


def upgrade() -> None:
    op.add_column("profiles", sa.Column("archived_at", TS, nullable=True))
    op.add_column("profiles", sa.Column("archive_reason", sa.Text(), nullable=True))
    op.add_column("profiles", sa.Column("archive_purge_after", TS, nullable=True))
    op.create_check_constraint(
        "archive_pair", "profiles", "(archived_at IS NULL) = (archive_reason IS NULL)"
    )
    op.create_check_constraint(
        "archive_reason",
        "profiles",
        "archive_reason IS NULL OR archive_reason IN ('owner_pending_deletion', 'owner_erased')",
    )
    op.create_check_constraint(
        "archive_managed", "profiles", "archived_at IS NULL OR kind = 'managed'"
    )
    op.create_check_constraint(
        "archive_purge_after",
        "profiles",
        "(archive_reason IS NOT DISTINCT FROM 'owner_erased') = (archive_purge_after IS NOT NULL)",
    )
    # The retention job finds expired archives by this date.
    op.create_index(
        "ix_profiles_archive_purge_after",
        "profiles",
        ["archive_purge_after"],
        postgresql_where=sa.text("archive_purge_after IS NOT NULL"),
    )
    op.execute(_GRANTS_GUARD_AFTER)
    op.execute(_INVITES_GUARD_AFTER)


def downgrade() -> None:
    archived = op.get_bind().execute(
        sa.text("SELECT count(*) FROM profiles WHERE archived_at IS NOT NULL")
    )
    if archived.scalar_one():
        raise RuntimeError("a profile is archived: purge or restore it first")
    op.execute(_INVITES_GUARD_BEFORE)
    op.execute(_GRANTS_GUARD_BEFORE)
    op.drop_index("ix_profiles_archive_purge_after", table_name="profiles")
    op.drop_constraint("archive_purge_after", "profiles", type_="check")
    op.drop_constraint("archive_managed", "profiles", type_="check")
    op.drop_constraint("archive_reason", "profiles", type_="check")
    op.drop_constraint("archive_pair", "profiles", type_="check")
    op.drop_column("profiles", "archive_purge_after")
    op.drop_column("profiles", "archive_reason")
    op.drop_column("profiles", "archived_at")
