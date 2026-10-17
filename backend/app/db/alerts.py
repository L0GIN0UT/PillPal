"""Missed-dose detector tables (ADR 0007): the alerts and the watermark.

``missed_dose_alerts`` is both the dedupe record (one alert per profile and occurrence, enforced
by ``UNIQUE(profile_id, occurrence_key)``) and the anchor of a later ``resolved`` push. Rows are
medical metadata (that a dose of this medication was missed, and when); they cascade with the
profile and the medication and are deleted after 72 hours by retention.

``detector_state`` holds one row, the watermark: everything before it has been looked at.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, ForeignKey, Index, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, sql_in
from app.db.models import NOW

ALERT_VARIANTS = ("missed", "unconfirmed")
# The detector's single ``detector_state`` row.
DETECTOR_NAME = "missed_dose"


class MissedDoseAlert(Base):
    __tablename__ = "missed_dose_alerts"
    __table_args__ = (
        UniqueConstraint("profile_id", "occurrence_key"),
        Index("ix_missed_dose_alerts_medication_id", "medication_id"),
        Index("ix_missed_dose_alerts_detected_at", "detected_at"),
        CheckConstraint(sql_in("variant", ALERT_VARIANTS), name="variant"),
        CheckConstraint("char_length(occurrence_key) <= 64", name="occurrence_key"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    profile_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("profiles.id", ondelete="CASCADE"))
    medication_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("medications.id", ondelete="CASCADE")
    )
    occurrence_key: Mapped[str] = mapped_column(Text)
    # The final due instant (the occurrence, or its latest snooze): the grant rule compares to it.
    due_at: Mapped[datetime]
    variant: Mapped[str] = mapped_column(Text)
    detected_at: Mapped[datetime] = mapped_column(server_default=NOW)
    # Set when a late ``taken`` / ``skipped`` arrives; the alert is never re-sent.
    resolved_at: Mapped[datetime | None]


class DetectorState(Base):
    __tablename__ = "detector_state"

    name: Mapped[str] = mapped_column(Text, primary_key=True)
    watermark: Mapped[datetime]
