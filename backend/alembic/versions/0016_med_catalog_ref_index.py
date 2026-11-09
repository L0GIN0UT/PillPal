"""Medications: the partial index that serves the contribution aggregate (milestone 4.7).

``(gtin, catalog_product_id) WHERE gtin_link_shared AND deleted_at IS NULL``: the opted-in links
of live rows (ADR 0014 §3). Built ``CONCURRENTLY`` in an autocommit block, so it is a revision
of its own: PostgreSQL cannot build an index concurrently inside a transaction, and a failure
here must not undo (or be hidden by) the column and CHECK changes of 0014.

A concurrent build that fails leaves an INVALID index behind, which a plain re-run would skip
(``IF NOT EXISTS`` sees the name). The revision drops such a leftover first, then creates the
index; both steps are repeatable, and the downgrade uses ``IF EXISTS``.

Revision ID: 0016_med_catalog_ref_index
Revises: 0015_med_manual_ingredients
Create Date: 2026-11-09
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0016_med_catalog_ref_index"
down_revision: str | None = "0015_med_manual_ingredients"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_INDEX = "ix_medications_gtin_link_shared"


def upgrade() -> None:
    with op.get_context().autocommit_block():
        invalid = op.get_bind().scalar(
            sa.text(
                "SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid "
                "WHERE c.relname = :name AND NOT i.indisvalid"
            ),
            {"name": _INDEX},
        )
        if invalid:
            op.drop_index(
                _INDEX, table_name="medications", postgresql_concurrently=True, if_exists=True
            )
        op.create_index(
            _INDEX,
            "medications",
            ["gtin", "catalog_product_id"],
            postgresql_where=sa.text("gtin_link_shared AND deleted_at IS NULL"),
            postgresql_concurrently=True,
            if_not_exists=True,
        )


def downgrade() -> None:
    with op.get_context().autocommit_block():
        op.drop_index(
            _INDEX, table_name="medications", postgresql_concurrently=True, if_exists=True
        )
