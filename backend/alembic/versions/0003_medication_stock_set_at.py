"""Medications: ``stock_set_at``, the instant the stock baseline was entered (TZ §2.4).

Stock is not decremented per dose: two devices recording doses offline would
lose decrements under last-write-wins. Clients derive the remaining amount as
``stock_count`` minus the doses taken after ``stock_set_at``, so the baseline
instant travels with the count in the same row (docs/adr/0004-stock-tracking.md).

The column is nullable and added without a default (a catalog-only change).
Like the other stock fields it is erased from tombstones: the tombstone CHECK
is replaced by one that also covers ``stock_set_at``. The new constraint is
added ``NOT VALID`` and validated separately, so the scan takes only a
SHARE UPDATE EXCLUSIVE lock; every existing row satisfies it because the new
column is NULL everywhere.

Revision ID: 0003_medication_stock_set_at
Revises: 0002_dose_event_snooze_until
Create Date: 2026-10-16
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

# Revision 0001 created its CHECK constraints through the naming convention with
# names that already carried the prefix, so the stored name is doubled; it is
# kept as is (renaming every constraint is a separate concern).
_TOMBSTONE_CHECK = "ck_medications_ck_medications_tombstone_erased"

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


def upgrade() -> None:
    op.add_column("medications", sa.Column("stock_set_at", sa.DateTime(timezone=True)))
    op.execute(f"ALTER TABLE medications DROP CONSTRAINT {_TOMBSTONE_CHECK}")
    op.execute(
        f"ALTER TABLE medications ADD CONSTRAINT {_TOMBSTONE_CHECK} "
        f"CHECK ({_ERASED_AFTER}) NOT VALID"
    )
    op.execute(f"ALTER TABLE medications VALIDATE CONSTRAINT {_TOMBSTONE_CHECK}")


def downgrade() -> None:
    # Drops the stock baselines; clients then fall back to the row's conflict key.
    op.execute(f"ALTER TABLE medications DROP CONSTRAINT {_TOMBSTONE_CHECK}")
    op.drop_column("medications", "stock_set_at")
    op.execute(
        f"ALTER TABLE medications ADD CONSTRAINT {_TOMBSTONE_CHECK} CHECK ({_ERASED_BEFORE})"
    )
