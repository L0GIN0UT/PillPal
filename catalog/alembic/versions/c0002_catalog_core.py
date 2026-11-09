"""catalog core: sources, import runs, the four levels, GTINs, recall flags

Revision ID: c0002_catalog_core
Revises: c0001_baseline
Create Date: 2026-11-09

docs/phase4-plan.md "Catalog database", ADR 0012. Public reference data only: no column here may
hold anything about a user, a device or a search (tests/test_privacy_boundary.py introspects it).
Rows are never deleted by an import: ``withdrawn_at`` marks a row the source no longer lists, and
user medications keep resolving it by id. ``sources`` is seeded here, once (arch review N5).
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "c0002_catalog_core"
down_revision: str | None = "c0001_baseline"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

MARKETS = "('ru', 'us', 'eu')"

# (code, name, license, attribution, url, enabled). Importers that do not exist yet, or that need
# the owner's act (ESKLP: no license text found; GRLS: manual export), start disabled.
SOURCES = (
    (
        "rxnorm",
        "RxNorm Prescribable Content",
        "NLM terms: attribution and disclaimer",
        "Substance and composition data: RxNorm, U.S. National Library of Medicine",
        "https://www.nlm.nih.gov/research/umls/rxnorm/",
        True,
    ),
    (
        "openfda_ndc",
        "openFDA National Drug Code directory",
        "CC0 (U.S. government work), per open.fda.gov/terms",
        "Product data: openFDA (U.S. FDA)",
        "https://open.fda.gov/apis/drug/ndc/",
        True,
    ),
    (
        "ema",
        "EMA medicines data (EPAR report)",
        "Reuse with acknowledgement of the source (EMA legal notice)",
        "Product data: European Medicines Agency",
        "https://www.ema.europa.eu/en/medicines/download-medicine-data",
        False,
    ),
    (
        "esklp",
        "Unified state catalog of medicines (ESKLP)",
        "No license text published; enabled only by the owner (docs/research/ru-sources.md)",
        "Data: ESKLP, Ministry of Health of Russia",
        "https://esklp.egisz.rosminzdrav.ru/",
        False,
    ),
    (
        "ru_roszdravnadzor",
        "Roszdravnadzor open data",
        "Open license: free, perpetual, commercial use, source link required",
        "Data: Roszdravnadzor (open data)",
        "https://roszdravnadzor.gov.ru/opendata",
        False,
    ),
    (
        "grls_manual",
        "State register of medicines (manual monthly export)",
        "Site terms forbid commercial reuse; manual export, gated like ESKLP",
        "Data: GRLS, Ministry of Health of Russia",
        "https://grls.rosminzdrav.ru/",
        False,
    ),
    (
        "wikidata",
        "Wikidata",
        "CC0",
        "Substance names: Wikidata",
        "https://www.wikidata.org/",
        False,
    ),
    (
        "consensus",
        "Package links confirmed by PillPal users",
        "Aggregates only (ADR 0014)",
        "Package links confirmed by PillPal users",
        "https://pillpal.invalid/catalog/consensus",
        True,
    ),
)

# Parents first.
TABLES = (
    "recall_flags",
    "gtins",
    "packages",
    "products",
    "composition_ingredients",
    "compositions",
    "substance_names",
    "substances",
    "import_runs",
    "sources",
)

GTIN_CHECK_DIGIT_FUNCTION = """
CREATE FUNCTION catalog.gtin_check_digit_ok(g text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
AS $$
    SELECT CASE WHEN g !~ '^[0-9]{14}$' THEN false
    ELSE (10 - (
        SELECT sum(substr(g, i, 1)::int * CASE WHEN i % 2 = 1 THEN 3 ELSE 1 END)
        FROM generate_series(1, 13) AS i
    ) % 10) % 10 = substr(g, 14, 1)::int
    END
$$
"""

# docs/spec/gtin.md section 3, from gtin14 only. Keep in sync with the vectors in
# spec/gtin-vectors (tests/importers/test_gtin_sql.py runs them through this function).
GTIN_SHAREABLE_FUNCTION = """
CREATE FUNCTION catalog.gtin_is_shareable(g text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
AS $$
    SELECT CASE
        WHEN g !~ '^[0-9]{14}$' THEN false
        -- GTIN-8 range (six zeros): RCN-8 when the first digit of the GTIN-8 is 0 or 2.
        WHEN g LIKE '000000%' THEN substr(g, 7, 1) NOT IN ('0', '2')
        -- indicator 9 (variable measure); GS1 prefixes 020-029, 040-049, 200-299.
        ELSE NOT (substr(g, 1, 1) = '9' OR substr(g, 2, 2) IN ('02', '04') OR substr(g, 2, 1) = '2')
    END
$$
"""


def _seed_sources() -> None:
    insert = sa.text(
        "INSERT INTO catalog.sources (code, name, license, attribution, url, enabled) "
        "VALUES (:code, :name, :license, :attribution, :url, :enabled)"
    )
    bind = op.get_bind()
    for code, name, license_, attribution, url, enabled in SOURCES:
        bind.execute(
            insert,
            {
                "code": code,
                "name": name,
                "license": license_,
                "attribution": attribution,
                "url": url,
                "enabled": enabled,
            },
        )


def upgrade() -> None:
    op.execute(GTIN_CHECK_DIGIT_FUNCTION)
    op.execute(GTIN_SHAREABLE_FUNCTION)

    op.execute(
        """
        CREATE TABLE catalog.sources (
            code text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,31}$'),
            name text NOT NULL,
            license text NOT NULL,
            attribution text NOT NULL,
            url text NOT NULL,
            enabled boolean NOT NULL DEFAULT true
        )
        """
    )
    _seed_sources()

    op.execute(
        """
        CREATE TABLE catalog.import_runs (
            id uuid PRIMARY KEY,
            source text NOT NULL REFERENCES catalog.sources (code),
            source_version text,
            snapshot_sha256 char(64) NOT NULL CHECK (snapshot_sha256 ~ '^[0-9a-f]{64}$'),
            status text NOT NULL CHECK (status IN ('running', 'succeeded', 'failed')),
            started_at timestamptz NOT NULL DEFAULT now(),
            finished_at timestamptz,
            counts jsonb NOT NULL DEFAULT '{}'::jsonb,
            error_code text,
            CONSTRAINT import_runs_finished_iff_not_running
                CHECK ((status = 'running') = (finished_at IS NULL)),
            CONSTRAINT import_runs_error_only_when_failed
                CHECK (status = 'failed' OR error_code IS NULL)
        )
        """
    )
    op.execute(
        "CREATE UNIQUE INDEX import_runs_one_running_per_source "
        "ON catalog.import_runs (source) WHERE status = 'running'"
    )

    op.execute(
        f"""
        CREATE TABLE catalog.substances (
            id uuid PRIMARY KEY,
            source text NOT NULL REFERENCES catalog.sources (code),
            source_key text NOT NULL CHECK (source_key <> ''),
            market text NOT NULL CHECK (market IN {MARKETS}),
            name_en text,
            name_ru text,
            withdrawn_at timestamptz,
            last_run_id uuid NOT NULL REFERENCES catalog.import_runs (id),
            CONSTRAINT substances_source_key_unique UNIQUE (source, source_key),
            CONSTRAINT substances_has_a_name CHECK (name_en IS NOT NULL OR name_ru IS NOT NULL)
        )
        """
    )
    op.execute(
        """
        CREATE TABLE catalog.substance_names (
            substance_id uuid NOT NULL REFERENCES catalog.substances (id),
            lang text NOT NULL CHECK (lang IN ('en', 'ru')),
            name text NOT NULL CHECK (btrim(name) <> ''),
            source text NOT NULL REFERENCES catalog.sources (code),
            PRIMARY KEY (substance_id, lang, name)
        )
        """
    )
    op.execute(
        f"""
        CREATE TABLE catalog.compositions (
            id uuid PRIMARY KEY,
            source text NOT NULL REFERENCES catalog.sources (code),
            source_key text NOT NULL CHECK (source_key <> ''),
            market text NOT NULL CHECK (market IN {MARKETS}),
            form_code text,
            form_name_en text,
            form_name_ru text,
            complete boolean NOT NULL DEFAULT false,
            identity_key char(64) NOT NULL CHECK (identity_key ~ '^[0-9a-f]{{64}}$'),
            withdrawn_at timestamptz,
            last_run_id uuid NOT NULL REFERENCES catalog.import_runs (id),
            CONSTRAINT compositions_source_key_unique UNIQUE (source, source_key),
            CONSTRAINT compositions_identity_unique UNIQUE (source, identity_key),
            CONSTRAINT compositions_complete_has_form CHECK (NOT complete OR form_code IS NOT NULL)
        )
        """
    )
    op.execute(
        """
        CREATE TABLE catalog.composition_ingredients (
            composition_id uuid NOT NULL REFERENCES catalog.compositions (id),
            substance_id uuid NOT NULL REFERENCES catalog.substances (id),
            strength_value numeric CHECK (strength_value > 0),
            strength_unit text,
            per_value numeric CHECK (per_value > 0),
            per_unit text,
            PRIMARY KEY (composition_id, substance_id),
            CONSTRAINT ingredients_strength_pair
                CHECK ((strength_value IS NULL) = (strength_unit IS NULL)),
            CONSTRAINT ingredients_per_pair CHECK ((per_value IS NULL) = (per_unit IS NULL))
        )
        """
    )
    op.execute(
        f"""
        CREATE TABLE catalog.products (
            id uuid PRIMARY KEY,
            source text NOT NULL REFERENCES catalog.sources (code),
            source_key text NOT NULL CHECK (source_key <> ''),
            market text NOT NULL CHECK (market IN {MARKETS}),
            brand_name text NOT NULL CHECK (btrim(brand_name) <> ''),
            manufacturer text,
            country text,
            composition_id uuid REFERENCES catalog.compositions (id),
            rx_status text,
            registration_number text,
            withdrawn_at timestamptz,
            last_run_id uuid NOT NULL REFERENCES catalog.import_runs (id),
            CONSTRAINT products_source_key_unique UNIQUE (source, source_key)
        )
        """
    )
    op.execute("CREATE INDEX products_composition_id ON catalog.products (composition_id)")
    op.execute(
        "CREATE INDEX products_registration_number ON catalog.products (registration_number)"
    )
    op.execute(
        """
        CREATE TABLE catalog.recall_flags (
            registration_number text NOT NULL,
            series text NOT NULL,
            reason_code text NOT NULL,
            source text NOT NULL REFERENCES catalog.sources (code),
            published_at timestamptz,
            PRIMARY KEY (registration_number, series, source)
        )
        """
    )
    op.execute(
        """
        CREATE TABLE catalog.packages (
            id uuid PRIMARY KEY,
            product_id uuid NOT NULL REFERENCES catalog.products (id),
            source text NOT NULL REFERENCES catalog.sources (code),
            source_key text NOT NULL CHECK (source_key <> ''),
            description text,
            count numeric CHECK (count > 0),
            count_unit text,
            withdrawn_at timestamptz,
            last_run_id uuid NOT NULL REFERENCES catalog.import_runs (id),
            CONSTRAINT packages_source_key_unique UNIQUE (source, source_key),
            CONSTRAINT packages_count_pair CHECK ((count IS NULL) = (count_unit IS NULL))
        )
        """
    )
    op.execute("CREATE INDEX packages_product_id ON catalog.packages (product_id)")
    # Keyed by (gtin, source): two sources may list one GTIN. Lookup precedence is admin lock,
    # then the official source by authority, then consensus (ADR 0012). The CHECK keeps
    # restricted and malformed numbers out even if an importer has a bug (ADR 0013).
    op.execute(
        """
        CREATE TABLE catalog.gtins (
            gtin char(14) NOT NULL,
            source text NOT NULL REFERENCES catalog.sources (code),
            package_id uuid NOT NULL REFERENCES catalog.packages (id),
            origin text NOT NULL CHECK (origin IN ('source', 'consensus', 'admin')),
            created_at timestamptz NOT NULL DEFAULT now(),
            withdrawn_at timestamptz,
            last_run_id uuid REFERENCES catalog.import_runs (id),
            PRIMARY KEY (gtin, source),
            CONSTRAINT gtins_valid_shareable CHECK (
                gtin ~ '^[0-9]{14}$'
                AND catalog.gtin_check_digit_ok(gtin::text)
                AND catalog.gtin_is_shareable(gtin::text)
            )
        )
        """
    )
    op.execute("CREATE INDEX gtins_package_id ON catalog.gtins (package_id)")


def downgrade() -> None:
    for table in TABLES:
        op.execute(f"DROP TABLE catalog.{table}")
    op.execute("DROP FUNCTION catalog.gtin_is_shareable(text)")
    op.execute("DROP FUNCTION catalog.gtin_check_digit_ok(text)")
