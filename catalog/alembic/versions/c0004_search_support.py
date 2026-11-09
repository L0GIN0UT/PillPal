"""search support: substance reverse index and the GTIN decisions the lookup reads

Revision ID: c0004_search_support
Revises: c0003_search_entries
Create Date: 2026-11-10

``composition_ingredients`` is keyed ``(composition_id, substance_id)``; searching by an INN walks
substance -> compositions -> products, which needs the reverse index (milestone 4.5).

``gtin_link_decisions`` is the table of ADR 0014 section 4 that ``/v1/gtins/lookup`` consults for
``disputed``, ``rejected`` and ``locked`` numbers. It is created here, empty, because the lookup
must answer those states from the first release; the consensus tables (candidates, audit) and the
code that writes decisions arrive with milestone 4.7 in the next revision.
"""

from collections.abc import Sequence

from alembic import op

revision: str = "c0004_search_support"
down_revision: str | None = "c0003_search_entries"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.execute(
        "CREATE INDEX composition_ingredients_substance_id "
        "ON catalog.composition_ingredients (substance_id)"
    )
    op.execute(
        """
        CREATE TABLE catalog.gtin_link_decisions (
            gtin char(14) PRIMARY KEY,
            status text NOT NULL
                CHECK (status IN ('pending', 'promoted', 'disputed', 'rejected', 'locked')),
            product_id uuid REFERENCES catalog.products (id),
            decided_by text NOT NULL CHECK (decided_by IN ('auto', 'admin')),
            decided_at timestamptz NOT NULL DEFAULT now(),
            reason_code text CHECK (reason_code IS NULL OR reason_code ~ '^[a-z_]{1,64}$'),
            CONSTRAINT gtin_link_decisions_valid_shareable CHECK (
                gtin ~ '^[0-9]{14}$'
                AND catalog.gtin_check_digit_ok(gtin::text)
                AND catalog.gtin_is_shareable(gtin::text)
            ),
            CONSTRAINT gtin_link_decisions_product CHECK (
                status NOT IN ('promoted', 'locked') OR product_id IS NOT NULL
            )
        )
        """
    )


def downgrade() -> None:
    op.execute("DROP TABLE catalog.gtin_link_decisions")
    op.execute("DROP INDEX catalog.composition_ingredients_substance_id")
