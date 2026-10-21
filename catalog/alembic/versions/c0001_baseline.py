"""baseline: extensions and the immutable unaccent wrapper

Revision ID: c0001_baseline
Revises:
Create Date: 2026-10-21

``pg_trgm`` serves typo-tolerant search and ``unaccent`` folds diacritics. ``unaccent`` is only
STABLE, so index expressions need an IMMUTABLE wrapper; the dictionary is passed explicitly and
schema-qualified, which is what makes the wrapper safe to declare immutable.
"""

from collections.abc import Sequence

from alembic import op

revision: str = "c0001_baseline"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.execute("CREATE SCHEMA catalog")
    op.execute("CREATE EXTENSION pg_trgm")
    op.execute("CREATE EXTENSION unaccent")
    op.execute(
        """
        CREATE FUNCTION catalog.unaccent_immutable(text) RETURNS text
        LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
        AS $$ SELECT public.unaccent('public.unaccent'::regdictionary, $1) $$
        """
    )


def downgrade() -> None:
    op.execute("DROP FUNCTION catalog.unaccent_immutable(text)")
    op.execute("DROP EXTENSION unaccent")
    op.execute("DROP EXTENSION pg_trgm")
    op.execute("DROP SCHEMA catalog")
