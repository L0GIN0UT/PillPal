"""Account data exports (Phase 5.5, ADR 0016 section 8; migration 0021).

A row is the request, the build state and - for at most ``EXPORT_TTL_HOURS`` - the encrypted
archive (``bytea``, AES-256-GCM, ``app.services.data_encryption``). ``family_id`` is the session
(refresh family) that asked: only it may download. Medical data, never exported itself, erased
with the account (``ON DELETE CASCADE``; a deletion request deletes the rows at once).
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, ForeignKey, Index, LargeBinary, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, sql_in
from app.db.models import NOW

EXPORT_STATUSES = ("queued", "running", "ready", "downloaded", "failed", "expired")
EXPORT_ERROR_CODES = ("export_too_large", "export_build_failed")
# Statuses in which the export is still on its way to the user.
ACTIVE_EXPORT_STATUSES = ("queued", "running", "ready")


class DataExport(Base):
    __tablename__ = "data_exports"
    __table_args__ = (
        CheckConstraint(sql_in("status", EXPORT_STATUSES), name="status"),
        CheckConstraint(
            f"error_code IS NULL OR {sql_in('error_code', EXPORT_ERROR_CODES)}", name="error_code"
        ),
        CheckConstraint("archive IS NULL OR status = 'ready'", name="archive_only_when_ready"),
        Index("ix_data_exports_user_id_requested_at", "user_id", "requested_at"),
        Index("ix_data_exports_status", "status"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    family_id: Mapped[uuid.UUID]
    status: Mapped[str] = mapped_column(Text)
    error_code: Mapped[str | None] = mapped_column(Text)
    requested_at: Mapped[datetime] = mapped_column(server_default=NOW)
    lease_until: Mapped[datetime | None]
    ready_at: Mapped[datetime | None]
    expires_at: Mapped[datetime | None]
    size_bytes: Mapped[int | None]
    # Deferred: status reads never load the blob.
    archive: Mapped[bytes | None] = mapped_column(LargeBinary, deferred=True)
