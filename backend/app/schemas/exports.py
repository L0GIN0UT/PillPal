"""Request and response models of the data export endpoints (ADR 0016 section 8)."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

ExportStatus = Literal["queued", "running", "ready", "downloaded", "failed", "expired"]


class ExportRequest(BaseModel):
    """Step-up re-authentication.

    Today the account password; the OAuth form (``reauth: {provider, platform, assertion}``)
    joins it in milestone 5.7, so the body is an object that can grow and is optional (a missing
    proof is a 401, not a 422).
    """

    model_config = ConfigDict(extra="forbid")

    password: Annotated[str, StringConstraints(max_length=128)] | None = None


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
