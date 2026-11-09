"""Bodies of the private ingest endpoint (ADR 0014 section 3): gtin, product id and count only."""

from __future__ import annotations

from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field

from catalog.schemas.common import RequestModel

Region = Literal["ru", "eu"]
REGIONS: tuple[Region, ...] = ("ru", "eu")
# Far beyond any real snapshot; keeps ``bigint`` columns and ``int`` arithmetic safe.
MAX_GENERATION = 2**62
MAX_PAGE = 100_000
MAX_COUNT = 10_000_000


class ConfirmationItem(RequestModel):
    gtin: str = Field(pattern=r"^[0-9]{14}$")
    product_id: UUID
    # A count of one would be a single person: the sender never reports it (CHECK >= 2).
    count: int = Field(ge=2, le=MAX_COUNT)


class SnapshotPage(RequestModel):
    generation: int = Field(ge=1, le=MAX_GENERATION)
    page: int = Field(ge=0, le=MAX_PAGE)
    complete: bool
    items: list[ConfirmationItem]


class IngestResult(BaseModel):
    status: Literal["staged", "committed", "duplicate"]
    dropped: int
