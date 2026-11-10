"""The Alembic history is linear: one head, and it is the one this branch expects."""

from __future__ import annotations

from alembic.script import ScriptDirectory

from tests.helpers import alembic_config

# Bump together with the new revision; a second head (two branches merged without a merge
# revision) fails here instead of at deploy time. Reading the scripts needs no database.
EXPECTED_HEAD = "0016_med_catalog_ref_index"


def test_single_head() -> None:
    script = ScriptDirectory.from_config(alembic_config("postgresql+asyncpg://unused/unused"))
    heads = script.get_heads()
    assert len(heads) == 1, f"merge the branches: {heads}"
    assert heads == [EXPECTED_HEAD]
