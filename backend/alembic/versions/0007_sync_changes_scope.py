"""Sync journal keyed by profile, and the ``privacy`` op (ADR 0006 §1, §4).

``sync_changes.user_id`` becomes ``profile_id`` (FK ``profiles.id`` ON DELETE
CASCADE, index ``(profile_id, seq)``): a pull reads the journal per scope, and a
scope can be shared with relatives. Existing rows are assigned to the profile of
the entity they point at. Rows whose entity no longer exists cannot be delivered
and are dropped. The op CHECK gains ``privacy`` (a privacy change of a
medication, journal only: it never appears on the wire).

The backfill runs in one step because no installation exists outside dev and CI
(docs/phase3-plan.md, Assumptions); with a stand it would be split into add,
backfill in batches, then switch.

Downgrade restores ``user_id`` from the profile's owner and turns ``privacy``
rows into ``upsert`` (the entity state is what a pull delivers anyway).

Revision ID: 0007_sync_changes_scope
Revises: 0006_profile_alert_settings
Create Date: 2026-10-17
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0007_sync_changes_scope"
down_revision: str | None = "0006_profile_alert_settings"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# Revision 0001 passed an already conventional name through the naming convention, which
# prefixed it a second time; the model's name is the single-prefixed one.
_OP_CHECK_0001 = "ck_sync_changes_ck_sync_changes_op"
_OP_CHECK = "ck_sync_changes_op"

# entity -> SQL that gives the profile id of each journal row of that entity.
_BACKFILL = {
    "profile": "UPDATE sync_changes sc SET profile_id = p.id FROM profiles p "
    "WHERE sc.entity = 'profile' AND sc.entity_id = p.id",
    "medication": "UPDATE sync_changes sc SET profile_id = m.profile_id FROM medications m "
    "WHERE sc.entity = 'medication' AND sc.entity_id = m.id",
    "schedule": "UPDATE sync_changes sc SET profile_id = m.profile_id "
    "FROM schedules s JOIN medications m ON m.id = s.medication_id "
    "WHERE sc.entity = 'schedule' AND sc.entity_id = s.id",
    "dose_event": "UPDATE sync_changes sc SET profile_id = d.profile_id FROM dose_events d "
    "WHERE sc.entity = 'dose_event' AND sc.entity_id = d.id",
}


def _swap_op_check(drop: str, add: str, ops: str) -> None:
    op.execute(f"ALTER TABLE sync_changes DROP CONSTRAINT {drop}")
    op.execute(f"ALTER TABLE sync_changes ADD CONSTRAINT {add} CHECK (op IN ({ops}))")


def upgrade() -> None:
    op.execute("SET LOCAL lock_timeout = '5s'")
    op.add_column("sync_changes", sa.Column("profile_id", sa.Uuid(), nullable=True))
    for statement in _BACKFILL.values():
        op.execute(statement)
    op.execute("DELETE FROM sync_changes WHERE profile_id IS NULL")
    op.alter_column("sync_changes", "profile_id", nullable=False)
    op.create_foreign_key(
        "fk_sync_changes_profile_id_profiles",
        "sync_changes",
        "profiles",
        ["profile_id"],
        ["id"],
        ondelete="CASCADE",
    )
    op.create_index("ix_sync_changes_profile_id_seq", "sync_changes", ["profile_id", "seq"])
    op.drop_index("ix_sync_changes_user_id_seq", table_name="sync_changes")
    op.drop_column("sync_changes", "user_id")  # drops its foreign key with it
    _swap_op_check(_OP_CHECK_0001, _OP_CHECK, "'upsert', 'delete', 'privacy'")
    op.execute("RESET lock_timeout")


def downgrade() -> None:
    op.execute("SET LOCAL lock_timeout = '5s'")
    op.execute(f"ALTER TABLE sync_changes DROP CONSTRAINT {_OP_CHECK}")
    op.execute("UPDATE sync_changes SET op = 'upsert' WHERE op = 'privacy'")
    op.execute(
        f"ALTER TABLE sync_changes ADD CONSTRAINT {_OP_CHECK_0001} "
        "CHECK (op IN ('upsert', 'delete'))"
    )
    op.add_column("sync_changes", sa.Column("user_id", sa.Uuid(), nullable=True))
    op.execute(
        "UPDATE sync_changes sc SET user_id = p.owner_user_id FROM profiles p "
        "WHERE p.id = sc.profile_id"
    )
    op.alter_column("sync_changes", "user_id", nullable=False)
    op.create_foreign_key(
        "fk_sync_changes_user_id_users",
        "sync_changes",
        "users",
        ["user_id"],
        ["id"],
        ondelete="CASCADE",
    )
    op.create_index("ix_sync_changes_user_id_seq", "sync_changes", ["user_id", "seq"])
    op.drop_column("sync_changes", "profile_id")  # drops its index and foreign key
    op.execute("RESET lock_timeout")
