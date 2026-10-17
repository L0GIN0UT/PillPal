"""Partial indexes of ``dose_events`` for the missed-dose detector (ADR 0007 §2).

Candidate B reads snoozes by ``snooze_until``, candidate C reads undos by ``recorded_at``. Both
are partial, so they hold only the (few) snooze and undo rows. The append-only trigger of
``dose_events`` is untouched and no row is rewritten.

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


def upgrade() -> None:
    op.create_index(
        "ix_dose_events_snooze_until",
        "dose_events",
        ["snooze_until"],
        postgresql_where=sa.text("type = 'snoozed'"),
    )
    op.create_index(
        "ix_dose_events_undo_recorded_at",
        "dose_events",
        ["recorded_at"],
        postgresql_where=sa.text("type = 'undo'"),
    )


def downgrade() -> None:
    op.drop_index("ix_dose_events_undo_recorded_at", table_name="dose_events")
    op.drop_index("ix_dose_events_snooze_until", table_name="dose_events")
