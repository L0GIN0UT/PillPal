"""Request and response models of the data export endpoints (ADR 0016 section 8)."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field

from app.schemas.reauth import ReauthProof

ExportStatus = Literal["queued", "running", "ready", "downloaded", "failed", "expired"]


class ExportRequest(ReauthProof):
    """Step-up re-authentication: the password, or a fresh assertion of a linked sign-in provider
    (ADR 0017 section 8). Exactly one of them; a missing proof is a 422 like in
    ``DELETE /v1/me``."""


class ExportOut(BaseModel):
    id: uuid.UUID
    status: ExportStatus
    error_code: Literal["export_too_large", "export_build_failed"] | None = None
    requested_at: datetime
    ready_at: datetime | None = Field(default=None, description="When the archive became ready")
    expires_at: datetime | None = Field(
        default=None, description="The archive can be downloaded until then, once"
    )
    size_bytes: int | None = Field(default=None, description="Size of the zip archive")
