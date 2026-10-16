"""Dose events: ``snooze_until`` for ``snoozed`` events (ADR 0001 §7).

Every device and the missed-dose detector must agree when a snoozed dose is
due again, so the instant travels with the event instead of being derived
from a per-device setting.

The column is nullable and added without a default (a catalog-only change).
Both CHECK constraints are added ``NOT VALID``: PostgreSQL enforces them for
every new row without scanning (or locking) existing ones. The window check
holds for all old rows (their ``snooze_until`` is NULL) and is validated
right away; "required for snoozed" is not, because rows written before this
revision may be ``snoozed`` without it and ``dose_events`` is append-only.

Revision ID: 0002_dose_event_snooze_until
Revises: 0001_initial
Create Date: 2026-10-16
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0002_dose_event_snooze_until"
down_revision: str | None = "0001_initial"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("dose_events", sa.Column("snooze_until", sa.DateTime(timezone=True)))
    op.execute(
        "ALTER TABLE dose_events ADD CONSTRAINT ck_dose_events_snooze_until "
        "CHECK ((type = 'snoozed') = (snooze_until IS NOT NULL)) NOT VALID"
    )
    op.execute(
        "ALTER TABLE dose_events ADD CONSTRAINT ck_dose_events_snooze_until_window "
        "CHECK (snooze_until IS NULL OR "
        "(snooze_until > at AND snooze_until <= at + interval '24 hours')) NOT VALID"
    )
    op.execute("ALTER TABLE dose_events VALIDATE CONSTRAINT ck_dose_events_snooze_until_window")


def downgrade() -> None:
    # Drops the snooze instants recorded since the upgrade; the events stay.
    op.execute("ALTER TABLE dose_events DROP CONSTRAINT ck_dose_events_snooze_until_window")
    op.execute("ALTER TABLE dose_events DROP CONSTRAINT ck_dose_events_snooze_until")
    op.drop_column("dose_events", "snooze_until")
