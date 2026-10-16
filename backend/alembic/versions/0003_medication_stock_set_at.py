"""Medications: ``stock_set_at``, the instant the stock baseline was entered (TZ §2.4).

Stock is not decremented per dose: two devices recording doses offline would
lose decrements under last-write-wins. Clients derive the remaining amount as
``stock_count`` minus the doses taken after ``stock_set_at``, so the baseline
instant travels with the count in the same row (docs/adr/0004-stock-tracking.md).

The column is nullable and added without a default (a catalog-only change).
Like the other stock fields it is erased from tombstones: the tombstone CHECK
is replaced by one that also covers ``stock_set_at``, and a new CHECK allows a
baseline only together with a count.

Locking: the revision runs in one transaction, so the ACCESS EXCLUSIVE lock
taken by ``ADD COLUMN`` is held until commit, including during the two
``VALIDATE`` scans (``NOT VALID`` + ``VALIDATE`` only splits the work; it does
not lower the lock here). ``medications`` is small (rows per user) and the new
column is NULL everywhere, so both checks hold for every row and the scans are
short; ``lock_timeout`` makes the migration fail fast instead of queueing
behind a long transaction and blocking every other query on the table.

Revision ID: 0003_medication_stock_set_at
Revises: 0002_dose_event_snooze_until
Create Date: 2026-10-16
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

# Revision 0001 created its CHECK constraints through the naming convention with
# names that already carried the prefix, so the stored names are doubled; new
# constraints of this table follow the same form so the table stays uniform
# (renaming every constraint is a separate concern).
_TOMBSTONE_CHECK = "ck_medications_ck_medications_tombstone_erased"
_BASELINE_CHECK = "ck_medications_ck_medications_stock_set_at"

revision: str = "0003_medication_stock_set_at"
down_revision: str | None = "0002_dose_event_snooze_until"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_ERASED_BEFORE = (
    "deleted_at IS NULL OR (name IS NULL AND form IS NULL AND strength_text IS NULL "
    "AND notes IS NULL AND stock_count IS NULL AND stock_unit IS NULL "
    "AND low_stock_days IS NULL)"
)
_ERASED_AFTER = (
    "deleted_at IS NULL OR (name IS NULL AND form IS NULL AND strength_text IS NULL "
    "AND notes IS NULL AND stock_count IS NULL AND stock_unit IS NULL "
    "AND low_stock_days IS NULL AND stock_set_at IS NULL)"
)
_BASELINE_NEEDS_COUNT = "stock_set_at IS NULL OR stock_count IS NOT NULL"


def upgrade() -> None:
    op.execute("SET LOCAL lock_timeout = '5s'")
    op.add_column("medications", sa.Column("stock_set_at", sa.DateTime(timezone=True)))
    op.execute(f"ALTER TABLE medications DROP CONSTRAINT {_TOMBSTONE_CHECK}")
    op.execute(
        f"ALTER TABLE medications ADD CONSTRAINT {_TOMBSTONE_CHECK} "
        f"CHECK ({_ERASED_AFTER}) NOT VALID"
    )
    op.execute(
        f"ALTER TABLE medications ADD CONSTRAINT {_BASELINE_CHECK} "
        f"CHECK ({_BASELINE_NEEDS_COUNT}) NOT VALID"
    )
    op.execute(f"ALTER TABLE medications VALIDATE CONSTRAINT {_TOMBSTONE_CHECK}")
    op.execute(f"ALTER TABLE medications VALIDATE CONSTRAINT {_BASELINE_CHECK}")


def downgrade() -> None:
    # Drops the stock baselines; clients then fall back to the row's conflict key.
    op.execute("SET LOCAL lock_timeout = '5s'")
    op.execute(f"ALTER TABLE medications DROP CONSTRAINT {_BASELINE_CHECK}")
    op.execute(f"ALTER TABLE medications DROP CONSTRAINT {_TOMBSTONE_CHECK}")
    op.drop_column("medications", "stock_set_at")
    op.execute(
        f"ALTER TABLE medications ADD CONSTRAINT {_TOMBSTONE_CHECK} CHECK ({_ERASED_BEFORE})"
    )
