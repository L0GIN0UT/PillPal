"""Medications: catalog references and the per-link contribution consent (ADR 0015 §4).

Adds opaque catalog ids (no foreign key: the catalog is another database), the ``gtin`` the user
scanned or typed, ``gtin_link_shared`` (the owner's opt-in to be counted for the link, ADR 0014
§2) and its server-set record (``gtin_link_consent_version``, ``gtin_link_consented_at``).

* Every column is nullable, except ``gtin_link_shared``: NOT NULL with a constant default, which
  PostgreSQL adds without rewriting the table. No row is touched; nobody is opted in.
* CHECKs are added ``NOT VALID`` and then validated: the flag needs a GTIN and a product, a
  live row only, and a consent record exactly when it is set. The tombstone CHECK is replaced
  by one that also covers the new columns (a tombstone keeps no reference and no consent).
* Locking: like 0003, the revision runs in one transaction, and the tombstone CHECK swap (DROP
  and re-ADD) and every ``ADD COLUMN`` take ACCESS EXCLUSIVE on ``medications`` until commit,
  including during the ``VALIDATE`` scans (``NOT VALID`` + ``VALIDATE`` only splits the work
  here, it does not lower the lock). That is acceptable for a table with a few rows per user
  and columns that are NULL or false everywhere, so the scans are short; ``lock_timeout`` makes
  the revision fail fast instead of queueing behind a long transaction and blocking the table.
* The partial index for the contribution aggregate is revision 0016 (it needs an autocommit
  block, and its failure modes differ).

Revision ID: 0014_medication_catalog_refs
Revises: 0013_dose_events_detector_idx
Create Date: 2026-11-09
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0014_medication_catalog_refs"
down_revision: str | None = "0013_dose_events_detector_idx"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# Stored names are doubled by revision 0001 (see 0003); new constraints of the table follow it.
_PREFIX = "ck_medications_ck_medications_"
_TOMBSTONE = f"{_PREFIX}tombstone_erased"

_ERASED_BEFORE = (
    "deleted_at IS NULL OR (name IS NULL AND form IS NULL AND strength_text IS NULL "
    "AND notes IS NULL AND stock_count IS NULL AND stock_unit IS NULL "
    "AND low_stock_days IS NULL AND stock_set_at IS NULL)"
)
_ERASED_AFTER = (
    "deleted_at IS NULL OR (name IS NULL AND form IS NULL AND strength_text IS NULL "
    "AND notes IS NULL AND stock_count IS NULL AND stock_unit IS NULL "
    "AND low_stock_days IS NULL AND stock_set_at IS NULL "
    "AND catalog_product_id IS NULL AND catalog_package_id IS NULL "
    "AND catalog_composition_id IS NULL AND gtin IS NULL "
    "AND gtin_link_consent_version IS NULL AND gtin_link_consented_at IS NULL)"
)
_NEW_CHECKS = {
    "gtin_format": "gtin IS NULL OR gtin ~ '^[0-9]{14}$'",
    "gtin_link_needs_refs": (
        "NOT gtin_link_shared OR (gtin IS NOT NULL AND catalog_product_id IS NOT NULL)"
    ),
    "gtin_link_live": "deleted_at IS NULL OR NOT gtin_link_shared",
    "gtin_link_consent_pair": (
        "(gtin_link_shared AND gtin_link_consent_version IS NOT NULL "
        "AND gtin_link_consented_at IS NOT NULL) "
        "OR (NOT gtin_link_shared AND gtin_link_consent_version IS NULL "
        "AND gtin_link_consented_at IS NULL)"
    ),
}


def upgrade() -> None:
    op.execute("SET LOCAL lock_timeout = '5s'")
    op.add_column("medications", sa.Column("catalog_product_id", sa.Uuid(), nullable=True))
    op.add_column("medications", sa.Column("catalog_package_id", sa.Uuid(), nullable=True))
    op.add_column("medications", sa.Column("catalog_composition_id", sa.Uuid(), nullable=True))
    op.add_column("medications", sa.Column("gtin", sa.Text(), nullable=True))
    op.add_column(
        "medications",
        sa.Column(
            "gtin_link_shared", sa.Boolean(), server_default=sa.text("false"), nullable=False
        ),
    )
    op.add_column("medications", sa.Column("gtin_link_consent_version", sa.Integer()))
    op.add_column("medications", sa.Column("gtin_link_consented_at", sa.DateTime(timezone=True)))
    op.execute(f"ALTER TABLE medications DROP CONSTRAINT {_TOMBSTONE}")
    op.execute(
        f"ALTER TABLE medications ADD CONSTRAINT {_TOMBSTONE} CHECK ({_ERASED_AFTER}) NOT VALID"
    )
    for name, condition in _NEW_CHECKS.items():
        op.execute(
            f"ALTER TABLE medications ADD CONSTRAINT {_PREFIX}{name} CHECK ({condition}) NOT VALID"
        )
    op.execute(f"ALTER TABLE medications VALIDATE CONSTRAINT {_TOMBSTONE}")
    for name in _NEW_CHECKS:
        op.execute(f"ALTER TABLE medications VALIDATE CONSTRAINT {_PREFIX}{name}")


def downgrade() -> None:
    # Drops the references and every consent: nobody stays opted in to a link that is gone.
    # (Revision 0016 drops the index first.)
    op.execute("SET LOCAL lock_timeout = '5s'")
    for name in _NEW_CHECKS:
        op.execute(f"ALTER TABLE medications DROP CONSTRAINT {_PREFIX}{name}")
    op.execute(f"ALTER TABLE medications DROP CONSTRAINT {_TOMBSTONE}")
    for column in (
        "gtin_link_consented_at",
        "gtin_link_consent_version",
        "gtin_link_shared",
        "gtin",
        "catalog_composition_id",
        "catalog_package_id",
        "catalog_product_id",
    ):
        op.drop_column("medications", column)
    op.execute(f"ALTER TABLE medications ADD CONSTRAINT {_TOMBSTONE} CHECK ({_ERASED_BEFORE})")
