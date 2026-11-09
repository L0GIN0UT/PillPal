"""Catalog cards: product, composition, package, and the GTIN lookup answer."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, Field, StringConstraints

from catalog.schemas.common import Market, RequestModel

GtinText = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=32)]


class IngredientOut(BaseModel):
    substance_id: UUID
    name_en: str | None
    name_ru: str | None
    strength_value: Decimal | None
    strength_unit: str | None
    per_value: Decimal | None
    per_unit: str | None


class CompositionOut(BaseModel):
    id: UUID
    form_code: str | None
    form_name_en: str | None
    form_name_ru: str | None
    complete: bool
    withdrawn: bool
    ingredients: list[IngredientOut]


class ProductOut(BaseModel):
    id: UUID
    source: str
    name: str
    market: Market
    country: str | None
    manufacturer: str | None
    rx_status: str | None
    registration_number: str | None
    withdrawn: bool


class PackageOut(BaseModel):
    id: UUID
    description: str | None
    count: Decimal | None
    count_unit: str | None
    withdrawn: bool
    gtins: list[str]


class RecallOut(BaseModel):
    """A recalled series of the product's registration (public regulatory data)."""

    series: str
    reason_code: str
    source: str
    published_at: datetime | None


class ProductGetRequest(RequestModel):
    id: UUID = Field(repr=False)


class ProductCard(BaseModel):
    product: ProductOut
    composition: CompositionOut | None
    packages: list[PackageOut]
    recalls: list[RecallOut]


class GtinLookupRequest(RequestModel):
    # Free text here, validated by the GTIN module: a bad number is ``422 invalid_gtin``.
    gtin: GtinText = Field(repr=False)


GtinStatus = Literal["found", "unknown", "restricted", "disputed"]


class GtinLookupResponse(BaseModel):
    status: GtinStatus
    product: ProductOut | None
    package: PackageOut | None
    composition: CompositionOut | None


class SourceOut(BaseModel):
    code: str
    name: str
    license: str
    attribution: str
    url: str
