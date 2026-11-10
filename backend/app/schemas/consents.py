"""Request/response models for consent records (Phase 5.2a)."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field

from app.domain.consents import MAX_CONSENT_VERSION, ConsentKind, ConsentSource

ConsentVersion = Annotated[int, Field(strict=True, ge=1, le=MAX_CONSENT_VERSION)]


class ConsentIn(BaseModel):
    """The text the user saw: its kind and the version the app displayed."""

    model_config = ConfigDict(extra="forbid")

    kind: ConsentKind
    version: ConsentVersion


class ConsentWithdrawIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    kind: ConsentKind


class ConsentWithdrawOut(BaseModel):
    reset_links: int = Field(description="Medication links to the catalog reset by the withdrawal")


class ConsentRecordOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    kind: ConsentKind
    version: int
    source: ConsentSource
    accepted_at: datetime
    withdrawn_at: datetime | None


class ConsentsOut(BaseModel):
    current: dict[str, int] = Field(description="The version the app must show, per kind")
    records: list[ConsentRecordOut] = Field(description="Every record, withdrawn ones included")
    missing: list[str] = Field(
        description="Required kinds without an active record of the current version"
    )
