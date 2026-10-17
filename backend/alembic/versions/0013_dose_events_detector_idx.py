"""Missed-dose detector: dose-event indexes and the journal lock function (ADR 0007 §2).

* Candidate B reads snoozes by ``snooze_until``, candidate C reads undos by ``recorded_at``. Both
  indexes are partial (only the few snooze and undo rows) and built ``CONCURRENTLY`` in an
  autocommit block, so a populated ``dose_events`` is not locked for writes. The append-only
  trigger is untouched and no row is rewritten.
* ``lock_journal_owners(text[])`` takes the journal advisory locks of many owners in one
  statement, in the order of their hash keys, by looping over a sorted query (a guaranteed
  order, unlike an aggregate over a subquery). ``app.services.changes.lock_journal`` calls it.

Revision ID: 0013_dose_events_detector_idx
Revises: 0012_missed_dose_alerts
Create Date: 2026-10-17
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0013_dose_events_detector_idx"
down_revision: str | None = "0012_missed_dose_alerts"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

LOCK_FUNCTION = """
CREATE FUNCTION lock_journal_owners(owners text[]) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    lock_key bigint;
BEGIN
    FOR lock_key IN
        SELECT DISTINCT hashtextextended(owner, 0) AS k FROM unnest(owners) AS owner ORDER BY k
    LOOP
        PERFORM pg_advisory_xact_lock(lock_key);
    END LOOP;
END
$$
"""


def upgrade() -> None:
    op.execute(LOCK_FUNCTION)
    with op.get_context().autocommit_block():
        op.create_index(
            "ix_dose_events_snooze_until",
            "dose_events",
            ["snooze_until"],
            postgresql_where=sa.text("type = 'snoozed'"),
            postgresql_concurrently=True,
        )
        op.create_index(
            "ix_dose_events_undo_recorded_at",
            "dose_events",
            ["recorded_at"],
            postgresql_where=sa.text("type = 'undo'"),
            postgresql_concurrently=True,
        )


def downgrade() -> None:
    with op.get_context().autocommit_block():
        op.drop_index(
            "ix_dose_events_undo_recorded_at",
            table_name="dose_events",
            postgresql_concurrently=True,
        )
        op.drop_index(
            "ix_dose_events_snooze_until", table_name="dose_events", postgresql_concurrently=True
        )
    op.execute("DROP FUNCTION lock_journal_owners(text[])")
