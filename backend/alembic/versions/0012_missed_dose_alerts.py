"""Missed-dose detector: ``missed_dose_alerts`` and ``detector_state`` (ADR 0007).

``missed_dose_alerts`` has ``UNIQUE(profile_id, occurrence_key)``: the insert of the detector is
``ON CONFLICT DO NOTHING``, so an occurrence is alerted once however many ticks look at it.
``detector_state`` is the single-row watermark, seeded with ``now()``: a fresh deployment does not
look backwards.

Revision ID: 0012_missed_dose_alerts
Revises: 0011_push_outbox
Create Date: 2026-10-17
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0012_missed_dose_alerts"
down_revision: str | None = "0011_push_outbox"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

NOW = sa.text("now()")
TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "missed_dose_alerts",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("profile_id", sa.Uuid(), nullable=False),
        sa.Column("medication_id", sa.Uuid(), nullable=False),
        sa.Column("occurrence_key", sa.Text(), nullable=False),
        sa.Column("due_at", TS, nullable=False),
        sa.Column("variant", sa.Text(), nullable=False),
        sa.Column("detected_at", TS, server_default=NOW, nullable=False),
        sa.Column("resolved_at", TS, nullable=True),
        sa.CheckConstraint(
            "variant IN ('missed', 'unconfirmed')", name="ck_missed_dose_alerts_variant"
        ),
        sa.CheckConstraint(
            "char_length(occurrence_key) <= 64", name="ck_missed_dose_alerts_occurrence_key"
        ),
        sa.ForeignKeyConstraint(
            ["profile_id"],
            ["profiles.id"],
            name="fk_missed_dose_alerts_profile_id_profiles",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["medication_id"],
            ["medications.id"],
            name="fk_missed_dose_alerts_medication_id_medications",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_missed_dose_alerts"),
        sa.UniqueConstraint(
            "profile_id", "occurrence_key", name="uq_missed_dose_alerts_profile_id_occurrence_key"
        ),
    )
    op.create_index("ix_missed_dose_alerts_medication_id", "missed_dose_alerts", ["medication_id"])
    op.create_index("ix_missed_dose_alerts_detected_at", "missed_dose_alerts", ["detected_at"])
    op.create_table(
        "detector_state",
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("watermark", TS, nullable=False),
        sa.PrimaryKeyConstraint("name", name="pk_detector_state"),
    )
    op.execute("INSERT INTO detector_state (name, watermark) VALUES ('missed_dose', now())")


def downgrade() -> None:
    op.drop_table("detector_state")
    op.drop_table("missed_dose_alerts")
