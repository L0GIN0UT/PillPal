"""Private notes about relatives: ``relative_notes`` (ADR 0020 section 4).

One short label per (author, subject profile), visible only to its author. A person with an
account is addressed by their self profile, a managed profile by its own id. Deleting the author
or the subject profile deletes the note; the relationship rule (a grant between the two) is
enforced by the service and by the daily retention sweep, not by a constraint.

Revision ID: 0025_relative_notes
Revises: 0024_password_change_purpose
Create Date: 2026-11-14
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0025_relative_notes"
down_revision: str | None = "0024_password_change_purpose"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "relative_notes",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("subject_profile_id", sa.Uuid(), nullable=False),
        sa.Column("note", sa.Text(), nullable=False),
        sa.Column("created_at", TS, server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", TS, server_default=sa.text("now()"), nullable=False),
        sa.PrimaryKeyConstraint("user_id", "subject_profile_id", name="pk_relative_notes"),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name="fk_relative_notes_user_id_users", ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["subject_profile_id"],
            ["profiles.id"],
            name="fk_relative_notes_subject_profile_id_profiles",
            ondelete="CASCADE",
        ),
        sa.CheckConstraint(
            "char_length(note) BETWEEN 1 AND 20", name="ck_relative_notes_note_length"
        ),
    )
    op.create_index(
        "ix_relative_notes_subject_profile_id", "relative_notes", ["subject_profile_id"]
    )


def downgrade() -> None:
    op.drop_table("relative_notes")
