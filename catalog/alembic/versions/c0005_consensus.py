"""consensus: confirmations from regions, the ingest state and the admin audit

Revision ID: c0005_consensus
Revises: c0004_search_support
Create Date: 2026-11-10

ADR 0014. ``gtin_link_decisions`` already exists (c0004: the public lookup reads it); this
revision adds the rest:

* ``gtin_link_candidates``: the committed confirmation counts per region, ``(gtin, product)``
  and a count. A count is a number of people the catalog cannot identify, never a person; the
  CHECK ``confirmations >= 2`` keeps a single person's link out even if a sender is wrong.
* ``gtin_candidate_staging``: the pages of a snapshot that is not complete yet. They replace the
  region's committed rows atomically on the ``complete`` page.
* ``gtin_ingest_state``: per region, the last committed generation and the unfinished one.
* ``admin_audit``: who (a token label) did what to which GTIN. No personal data.

Every table that holds a GTIN has the same shareable CHECK as ``gtins``: a restricted number
cannot enter even through a bug (``docs/spec/gtin.md`` section 3).
"""

from collections.abc import Sequence

from alembic import op

revision: str = "c0005_consensus"
down_revision: str | None = "c0004_search_support"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

REGIONS = "('ru', 'eu')"
SHAREABLE = """CHECK (
                gtin ~ '^[0-9]{14}$'
                AND catalog.gtin_check_digit_ok(gtin::text)
                AND catalog.gtin_is_shareable(gtin::text)
            )"""


def upgrade() -> None:
    op.execute(
        f"""
        CREATE TABLE catalog.gtin_link_candidates (
            region text NOT NULL CHECK (region IN {REGIONS}),
            gtin char(14) NOT NULL,
            product_id uuid NOT NULL REFERENCES catalog.products (id),
            confirmations integer NOT NULL CHECK (confirmations >= 2),
            PRIMARY KEY (region, gtin, product_id),
            CONSTRAINT gtin_link_candidates_shareable {SHAREABLE}
        )
        """
    )
    op.execute("CREATE INDEX gtin_link_candidates_gtin ON catalog.gtin_link_candidates (gtin)")
    op.execute(
        f"""
        CREATE TABLE catalog.gtin_candidate_staging (
            region text NOT NULL CHECK (region IN {REGIONS}),
            generation bigint NOT NULL CHECK (generation >= 1),
            gtin char(14) NOT NULL,
            product_id uuid NOT NULL REFERENCES catalog.products (id),
            confirmations integer NOT NULL CHECK (confirmations >= 2),
            PRIMARY KEY (region, generation, gtin, product_id),
            CONSTRAINT gtin_candidate_staging_shareable {SHAREABLE}
        )
        """
    )
    op.execute(
        f"""
        CREATE TABLE catalog.gtin_ingest_state (
            region text PRIMARY KEY CHECK (region IN {REGIONS}),
            committed_generation bigint NOT NULL DEFAULT 0 CHECK (committed_generation >= 0),
            committed_at timestamptz,
            staging_generation bigint CHECK (staging_generation >= 1),
            staged_pages integer[] NOT NULL DEFAULT '{{}}',
            staged_items integer NOT NULL DEFAULT 0 CHECK (staged_items >= 0)
        )
        """
    )
    op.execute(
        f"""
        CREATE TABLE catalog.admin_audit (
            id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            at timestamptz NOT NULL DEFAULT now(),
            admin_name text NOT NULL CHECK (admin_name ~ '^[a-z0-9][a-z0-9_-]{{0,31}}$'),
            action text NOT NULL CHECK (action IN ('promote', 'reject', 'lock')),
            gtin char(14) NOT NULL,
            product_id uuid,
            CONSTRAINT admin_audit_shareable {SHAREABLE}
        )
        """
    )


def downgrade() -> None:
    for table in ("admin_audit", "gtin_ingest_state", "gtin_candidate_staging"):
        op.execute(f"DROP TABLE catalog.{table}")
    op.execute("DROP TABLE catalog.gtin_link_candidates")
