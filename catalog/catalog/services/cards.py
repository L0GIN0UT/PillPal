"""Catalog cards (product with composition, substances, packages) and the GTIN lookup answer.

Withdrawn rows stay resolvable by id because user medications reference them (ADR 0012 section 3);
they carry ``withdrawn = true`` for the label.
"""

from __future__ import annotations

from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from catalog.domain.gtin import GtinError, normalize
from catalog.errors import AppError
from catalog.schemas.cards import (
    CompositionOut,
    GtinLookupResponse,
    IngredientOut,
    PackageOut,
    ProductCard,
    ProductOut,
    RecallOut,
)
from catalog.services.gtins import resolve_gtin

_PRODUCT = text(
    """
SELECT id, source, brand_name AS name, market, country, manufacturer, rx_status,
       registration_number, withdrawn_at IS NOT NULL AS withdrawn, composition_id
  FROM catalog.products WHERE id = :id
"""
)
_COMPOSITION = text(
    """
SELECT id, form_code, form_name_en, form_name_ru, complete, withdrawn_at IS NOT NULL AS withdrawn
  FROM catalog.compositions WHERE id = :id
"""
)
_INGREDIENTS = text(
    """
SELECT ci.substance_id, s.name_en, s.name_ru, ci.strength_value, ci.strength_unit,
       ci.per_value, ci.per_unit
  FROM catalog.composition_ingredients ci
  JOIN catalog.substances s ON s.id = ci.substance_id
 WHERE ci.composition_id = :id
 ORDER BY coalesce(s.name_en, s.name_ru), s.id
"""
)
_PACKAGES = text(
    """
SELECT pk.id, pk.description, pk.count, pk.count_unit, pk.withdrawn_at IS NOT NULL AS withdrawn,
       ARRAY(
           SELECT DISTINCT g.gtin FROM catalog.gtins g
            WHERE g.package_id = pk.id AND g.withdrawn_at IS NULL ORDER BY g.gtin
       ) AS gtins
  FROM catalog.packages pk
 WHERE pk.product_id = :product AND (CAST(:only AS uuid) IS NULL OR pk.id = :only)
 ORDER BY (pk.withdrawn_at IS NOT NULL), pk.description, pk.id
"""
)
_RECALLS = text(
    """
SELECT series, reason_code, source, published_at
  FROM catalog.recall_flags WHERE registration_number = :number ORDER BY series, source
"""
)


async def _composition(session: AsyncSession, composition_id: UUID | None) -> CompositionOut | None:
    if composition_id is None:
        return None
    head = (await session.execute(_COMPOSITION, {"id": composition_id})).mappings().one()
    ingredients = (await session.execute(_INGREDIENTS, {"id": composition_id})).mappings().all()
    return CompositionOut(
        **head, ingredients=[IngredientOut.model_validate(dict(i)) for i in ingredients]
    )


async def _packages(
    session: AsyncSession, product_id: UUID, only: UUID | None = None
) -> list[PackageOut]:
    rows = (await session.execute(_PACKAGES, {"product": product_id, "only": only})).mappings()
    return [
        PackageOut.model_validate({**row, "gtins": [str(g) for g in row["gtins"]]}) for row in rows
    ]


async def product_card(session: AsyncSession, product_id: UUID) -> ProductCard | None:
    row = (await session.execute(_PRODUCT, {"id": product_id})).mappings().one_or_none()
    if row is None:
        return None
    number = row["registration_number"]
    recalls = (
        (await session.execute(_RECALLS, {"number": number})).mappings().all() if number else []
    )
    return ProductCard(
        product=ProductOut.model_validate(dict(row)),
        composition=await _composition(session, row["composition_id"]),
        packages=await _packages(session, product_id),
        recalls=[RecallOut.model_validate(dict(r)) for r in recalls],
    )


async def lookup_gtin(session: AsyncSession, raw: str) -> GtinLookupResponse:
    try:
        gtin = normalize(raw)
    except GtinError:
        raise AppError(422, "invalid_gtin", "Not a valid GTIN") from None
    if gtin.classification == "restricted":
        return GtinLookupResponse(status="restricted", product=None, package=None, composition=None)
    match = await resolve_gtin(session, gtin.gtin14)
    if match.status != "found" or match.product_id is None:
        return GtinLookupResponse(
            status="disputed" if match.status == "disputed" else "unknown",
            product=None,
            package=None,
            composition=None,
        )
    card = await product_card(session, match.product_id)
    if card is None:  # a decision names a product that is gone: nothing to answer with
        return GtinLookupResponse(status="unknown", product=None, package=None, composition=None)
    packages = (
        await _packages(session, match.product_id, only=match.package_id)
        if match.package_id is not None
        else []
    )
    return GtinLookupResponse(
        status="found",
        product=card.product,
        package=packages[0] if packages else None,
        composition=card.composition,
    )
