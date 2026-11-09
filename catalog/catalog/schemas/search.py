"""POST /v1/search (docs/phase4-plan.md, Search design)."""

from __future__ import annotations

from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, Field, StringConstraints

from catalog.schemas.common import Lang, Market, RequestModel

QUERY_MIN_LENGTH = 2
QUERY_MAX_LENGTH = 100
DEFAULT_LIMIT = 20

SearchKind = Literal["product", "substance"]


class SearchRequest(RequestModel):
    # ``repr=False``: what a person types must not reach a log through a model repr.
    q: Annotated[
        str,
        StringConstraints(
            strip_whitespace=True, min_length=QUERY_MIN_LENGTH, max_length=QUERY_MAX_LENGTH
        ),
    ] = Field(repr=False)
    lang: Lang
    market: Market | None = None
    kind: SearchKind = "product"
    limit: int = Field(
        default=DEFAULT_LIMIT,
        ge=1,
        description="Values above the server maximum (20 by default) are clamped, not rejected.",
    )


class SearchResult(BaseModel):
    kind: SearchKind
    id: UUID
    name: str
    market: Market
    country: str | None
    manufacturer: str | None
    form: str | None
    substances: list[str]
    withdrawn: bool


class SearchResponse(BaseModel):
    mode: Literal["text", "gtin"]
    results: list[SearchResult]
