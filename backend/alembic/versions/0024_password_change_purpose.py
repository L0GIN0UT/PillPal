"""E-mail code purpose ``password_change`` (change the password while signed in).

``email_codes.purpose`` gains ``password_change``; the code is bound to the refresh family that
asked for it (``hash_scope`` in the keyed hash, nothing stored), so no column is added. The
downgrade deletes the rows of the new purpose first: they would violate the old CHECK.

Revision ID: 0024_password_change_purpose
Revises: 0023_purchases
Create Date: 2026-11-11
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0024_password_change_purpose"
down_revision: str | None = "0023_purchases"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_PURPOSE_CHECK = "ck_email_codes_purpose"
_BEFORE = "'verify_email', 'password_reset', 'restore_account'"
_AFTER = f"{_BEFORE}, 'password_change'"


def _swap_purpose_check(purposes: str) -> None:
    # op.f: the name is already final, the naming convention must not prefix it again.
    op.drop_constraint(op.f(_PURPOSE_CHECK), "email_codes", type_="check")
    op.create_check_constraint(op.f(_PURPOSE_CHECK), "email_codes", f"purpose IN ({purposes})")


def upgrade() -> None:
    _swap_purpose_check(_AFTER)


def downgrade() -> None:
    op.execute("DELETE FROM email_codes WHERE purpose = 'password_change'")
    _swap_purpose_check(_BEFORE)
