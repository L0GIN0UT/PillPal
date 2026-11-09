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
* ``gtin_ingest_state``: per region, the last committed generation and time, and the unfinished
  generation with the pages received.
* ``admin_audit``: who (a token label) did what to which GTIN (or which region's ingest state),
  with the decision that was replaced. No personal data.
* the one synthetic ``import_runs`` row that carries every consensus package
  (``packages.last_run_id`` is mandatory): created here, so no code path has to create it
  under a lock.
* ``packages_consensus_gtin``: the consensus package of a GTIN is found by an index, so a
  commit of thousands of GTINs is not quadratic.

Downgrade drops the four tables and the index. Rows the consensus code wrote into earlier
tables stay (the synthetic run, ``source = 'consensus'`` packages and ``gtins`` rows, and
``gtin_link_decisions`` rows): they are catalog data the lookup relies on, and removing them
would silently unlink packages users already rely on.

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
# uuid5(CATALOG_NAMESPACE, "consensus:run") and sha256(b"consensus"); a test recomputes both.
CONSENSUS_RUN_ID = "31ac4a0c-75d8-56a4-a8aa-4fad1306abe4"
CONSENSUS_RUN_DIGEST = "c983c585ac3c40d920834f96200066352ff58e323da4dadae1d948fb27e63f82"
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
            page integer NOT NULL CHECK (page >= 0),
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
            staged_pages integer[] NOT NULL DEFAULT '{{}}'
        )
        """
    )
    op.execute(
        f"""
        CREATE TABLE catalog.admin_audit (
            id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            at timestamptz NOT NULL DEFAULT now(),
            admin_name text NOT NULL CHECK (admin_name ~ '^[a-z0-9][a-z0-9_-]{{0,31}}$'),
            action text NOT NULL
                CHECK (action IN ('promote', 'reject', 'lock', 'ingest_reset')),
            gtin char(14),
            product_id uuid,
            region text CHECK (region IN {REGIONS}),
            previous_status text,
            previous_product_id uuid,
            CONSTRAINT admin_audit_shareable {SHAREABLE},
            CONSTRAINT admin_audit_target CHECK ((action = 'ingest_reset') = (region IS NOT NULL))
        )
        """
    )
    op.execute(
        "CREATE INDEX packages_consensus_gtin "
        "ON catalog.packages (split_part(source_key, ':', 1)) WHERE source = 'consensus'"
    )
    op.execute(
        "INSERT INTO catalog.import_runs (id, source, snapshot_sha256, status, finished_at) "  # noqa: S608
        f"VALUES ('{CONSENSUS_RUN_ID}', 'consensus', '{CONSENSUS_RUN_DIGEST}', "
        "'succeeded', now()) ON CONFLICT (id) DO NOTHING"
    )


def downgrade() -> None:
    op.execute("DROP INDEX catalog.packages_consensus_gtin")
    for table in ("admin_audit", "gtin_ingest_state", "gtin_candidate_staging"):
        op.execute(f"DROP TABLE catalog.{table}")
    op.execute("DROP TABLE catalog.gtin_link_candidates")
