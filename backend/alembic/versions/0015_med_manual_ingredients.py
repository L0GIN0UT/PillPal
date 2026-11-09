"""Medications: ``manual_ingredients``, a private composition typed by the user (ADR 0015 §4).

A jsonb array of at most ten ``{substance_id?, name, strength_text?}`` items (the items are
validated by the API schema; the database keeps the shape and the bound). Nullable and added
without a default: a catalog-only change.

Like the references of 0014 it is erased from tombstones, so the tombstone CHECK is replaced by
one that also covers it (``NOT VALID``, then ``VALIDATE``; the column is NULL everywhere, so
both scans are short). 0014 could not name the column yet, so this is the second and last
change of that CHECK; all other reference and consent CHECKs are in 0014.

Revision ID: 0015_med_manual_ingredients
Revises: 0014_medication_catalog_refs
Create Date: 2026-11-09
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB

from alembic import op

revision: str = "0015_med_manual_ingredients"
down_revision: str | None = "0014_medication_catalog_refs"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_PREFIX = "ck_medications_ck_medications_"
_TOMBSTONE = f"{_PREFIX}tombstone_erased"
_SHAPE = f"{_PREFIX}manual_ingredients"

_ERASED_0014 = (
    "deleted_at IS NULL OR (name IS NULL AND form IS NULL AND strength_text IS NULL "
    "AND notes IS NULL AND stock_count IS NULL AND stock_unit IS NULL "
    "AND low_stock_days IS NULL AND stock_set_at IS NULL "
    "AND catalog_product_id IS NULL AND catalog_package_id IS NULL "
    "AND catalog_composition_id IS NULL AND gtin IS NULL "
    "AND gtin_link_consent_version IS NULL AND gtin_link_consented_at IS NULL)"
)
_ERASED_0015 = _ERASED_0014[:-1] + " AND manual_ingredients IS NULL)"
_SHAPE_CHECK = (
    "manual_ingredients IS NULL OR (jsonb_typeof(manual_ingredients) = 'array' "
    "AND jsonb_array_length(manual_ingredients) <= 10)"
)


def upgrade() -> None:
    op.execute("SET LOCAL lock_timeout = '5s'")
    op.add_column("medications", sa.Column("manual_ingredients", JSONB(), nullable=True))
    op.execute(f"ALTER TABLE medications DROP CONSTRAINT {_TOMBSTONE}")
    op.execute(
        f"ALTER TABLE medications ADD CONSTRAINT {_TOMBSTONE} CHECK ({_ERASED_0015}) NOT VALID"
    )
    op.execute(f"ALTER TABLE medications ADD CONSTRAINT {_SHAPE} CHECK ({_SHAPE_CHECK}) NOT VALID")
    op.execute(f"ALTER TABLE medications VALIDATE CONSTRAINT {_TOMBSTONE}")
    op.execute(f"ALTER TABLE medications VALIDATE CONSTRAINT {_SHAPE}")


def downgrade() -> None:
    op.execute("SET LOCAL lock_timeout = '5s'")
    op.execute(f"ALTER TABLE medications DROP CONSTRAINT {_SHAPE}")
    op.execute(f"ALTER TABLE medications DROP CONSTRAINT {_TOMBSTONE}")
    op.drop_column("medications", "manual_ingredients")
    op.execute(f"ALTER TABLE medications ADD CONSTRAINT {_TOMBSTONE} CHECK ({_ERASED_0014})")
