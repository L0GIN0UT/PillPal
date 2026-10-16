"""Account deletion grace period: ``users`` columns and the ``restore_account`` code purpose.

``deletion_requested_at`` and ``erase_after`` are set together by ``DELETE /v1/me`` and
cleared together by a restore; ``erase_after`` is later than the request (CHECKs), and a
partial index serves the hourly erase job. ``pending_deletion`` is exactly
``deletion_requested_at IS NOT NULL`` (ADR 0010). ``tokens_not_before`` makes every
access token issued before it unusable (compared with the token's ``iat``).

``email_codes.purpose`` gains ``restore_account`` (the restore flow's one-time code).

Downgrade is refused while an account is pending deletion: dropping the columns would
turn a deletion that the user requested into a live account.

Revision ID: 0008_user_deletion_grace
Revises: 0007_sync_changes_scope
Create Date: 2026-10-17
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0008_user_deletion_grace"
down_revision: str | None = "0007_sync_changes_scope"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

TS = sa.DateTime(timezone=True)
# Revision 0001 passed an already conventional name through the naming convention, which
# prefixed it a second time; the model's name is the single-prefixed one.
_PURPOSE_CHECK_0001 = "ck_email_codes_ck_email_codes_purpose"
_PURPOSE_CHECK = "ck_email_codes_purpose"


def _swap_purpose_check(old: str, new: str, purposes: str) -> None:
    # op.f: the names are already final, the naming convention must not prefix them again.
    op.drop_constraint(op.f(old), "email_codes", type_="check")
    op.create_check_constraint(op.f(new), "email_codes", f"purpose IN ({purposes})")


def upgrade() -> None:
    op.add_column("users", sa.Column("deletion_requested_at", TS, nullable=True))
    op.add_column("users", sa.Column("erase_after", TS, nullable=True))
    op.add_column("users", sa.Column("tokens_not_before", TS, nullable=True))
    op.create_check_constraint(
        "deletion_pair",
        "users",
        "(deletion_requested_at IS NULL) = (erase_after IS NULL)",
    )
    op.create_check_constraint(
        "deletion_erase_after",
        "users",
        "erase_after IS NULL OR erase_after > deletion_requested_at",
    )
    op.create_index(
        "ix_users_erase_after",
        "users",
        ["erase_after"],
        postgresql_where=sa.text("erase_after IS NOT NULL"),
    )
    _swap_purpose_check(
        _PURPOSE_CHECK_0001, _PURPOSE_CHECK, "'verify_email', 'password_reset', 'restore_account'"
    )


def downgrade() -> None:
    pending = op.get_bind().execute(
        sa.text("SELECT count(*) FROM users WHERE deletion_requested_at IS NOT NULL")
    )
    if pending.scalar_one():
        raise RuntimeError("an account is pending deletion: erase or restore it first")
    op.execute("DELETE FROM email_codes WHERE purpose = 'restore_account'")
    _swap_purpose_check(_PURPOSE_CHECK, _PURPOSE_CHECK_0001, "'verify_email', 'password_reset'")
    op.drop_index("ix_users_erase_after", table_name="users")
    op.drop_constraint("deletion_erase_after", "users", type_="check")
    op.drop_constraint("deletion_pair", "users", type_="check")
    op.drop_column("users", "tokens_not_before")
    op.drop_column("users", "erase_after")
    op.drop_column("users", "deletion_requested_at")
