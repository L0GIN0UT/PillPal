"""Bodies of the admin endpoints (ADR 0014 section 5). Catalog data and counts only."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel

from catalog.schemas.common import RequestModel


class ResolveRequest(RequestModel):
    action: Literal["promote", "reject", "lock"]
    product_id: uuid.UUID | None = None


class ResolveResponse(BaseModel):
    gtin: str
    status: Literal["pending", "promoted", "disputed", "rejected", "locked"]
    product_id: uuid.UUID | None
    decided_by: Literal["auto", "admin"]
    reason_code: str


class DisputeCandidate(BaseModel):
    product_id: uuid.UUID
    name: str
    confirmations: int


class Dispute(BaseModel):
    gtin: str
    decided_at: datetime
    official_product_id: uuid.UUID | None
    candidates: list[DisputeCandidate]


class DisputePage(BaseModel):
    items: list[Dispute]
    next_after: str | None


class ImportRunItem(BaseModel):
    id: uuid.UUID
    source: str
    source_version: str | None
    status: str
    started_at: datetime
    finished_at: datetime | None
    counts: dict[str, Any]
    error_code: str | None


class ImportRunPage(BaseModel):
    items: list[ImportRunItem]
