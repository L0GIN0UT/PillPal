"""The Alembic history is linear: one head, and it is the one this branch expects."""

from __future__ import annotations

from alembic.script import ScriptDirectory

from tests.helpers import alembic_config


def test_single_head() -> None:
    """Two branches merged without a merge revision fail here instead of at deploy time.

    Reading the scripts needs no database.
    """
    script = ScriptDirectory.from_config(alembic_config("postgresql+asyncpg://unused/unused"))
    heads = script.get_heads()
    assert len(heads) == 1, f"merge the branches: {heads}"
    ancestors = {rev.revision for rev in script.iterate_revisions(heads[0], "base")}
    assert "0017_consents" in ancestors
    assert "0022_auth_identities" in ancestors
