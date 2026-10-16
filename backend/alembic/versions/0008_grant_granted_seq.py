"""``profile_grants.granted_seq``: the scope's journal head when the grant was made (ADR 0006 §4).

A relative's pull must not learn that medications existed, were narrowed or were
deleted before the grant: it could never have held them. ``created_at`` cannot
tell, because ``seq`` is allocated at INSERT and ``created_at`` at the grant's own
clock; ``seq`` under the owner's journal lock is exact (``accept_invite`` reads the
head while holding it). Existing grants get the current head of their profile,
the safe direction: nothing before the migration is ever sent as a narrowing or
a tombstone to an existing relative.

Revision ID: 0008_grant_granted_seq
Revises: 0007_sync_changes_scope
Create Date: 2026-10-17
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0008_grant_granted_seq"
down_revision: str | None = "0007_sync_changes_scope"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "profile_grants",
        sa.Column("granted_seq", sa.BigInteger(), server_default=sa.text("0"), nullable=False),
    )
    op.execute(
        "UPDATE profile_grants g SET granted_seq = COALESCE("
        "(SELECT max(sc.seq) FROM sync_changes sc WHERE sc.profile_id = g.profile_id), 0)"
    )
    op.create_check_constraint(
        "ck_profile_grants_granted_seq", "profile_grants", "granted_seq >= 0"
    )


def downgrade() -> None:
    op.drop_constraint("ck_profile_grants_granted_seq", "profile_grants", type_="check")
    op.drop_column("profile_grants", "granted_seq")
