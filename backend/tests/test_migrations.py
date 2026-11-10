"""The Alembic history is linear: one head, and it is the one this branch expects."""

from __future__ import annotations

from alembic.script import ScriptDirectory

from tests.helpers import alembic_config

EXPECTED_HEAD = "0017_consents"


def test_single_head() -> None:
    """Two branches merged without a merge revision fail here instead of at deploy time.

    Reading the scripts needs no database.
    """
    script = ScriptDirectory.from_config(alembic_config("postgresql+asyncpg://unused/unused"))
    heads = script.get_heads()
    assert len(heads) == 1, f"merge the branches: {heads}"
    assert heads == [EXPECTED_HEAD], "a new migration updates EXPECTED_HEAD"
