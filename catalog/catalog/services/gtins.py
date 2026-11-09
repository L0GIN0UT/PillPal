"""Which product a GTIN belongs to (ADR 0014 section 4, docs/spec/gtin.md).

Precedence among the rows of one number: the product an admin locked, then rows that are not
withdrawn, then ``admin`` > ``source`` > ``consensus`` origin, then the source code and package id
(deterministic). A ``disputed`` decision answers without a product; ``rejected`` answers unknown.
Restricted numbers are never looked up (the table CHECK keeps them out anyway).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

_DECISION = text("SELECT status, product_id FROM catalog.gtin_link_decisions WHERE gtin = :gtin")

_ROWS = text(
    """
SELECT pk.id AS package_id, pk.product_id
  FROM catalog.gtins g
  JOIN catalog.packages pk ON pk.id = g.package_id
  JOIN catalog.products p ON p.id = pk.product_id
 WHERE g.gtin = :gtin
 ORDER BY (pk.product_id IS NOT DISTINCT FROM CAST(:locked AS uuid)) DESC,
          (g.withdrawn_at IS NOT NULL OR pk.withdrawn_at IS NOT NULL
              OR p.withdrawn_at IS NOT NULL),
          CASE g.origin WHEN 'admin' THEN 0 WHEN 'source' THEN 1 ELSE 2 END,
          g.source, pk.id
 LIMIT 1
"""
)


@dataclass(frozen=True, slots=True)
class GtinMatch:
    status: Literal["found", "unknown", "disputed"]
    product_id: UUID | None = None
    package_id: UUID | None = None


async def resolve_gtin(session: AsyncSession, gtin14: str) -> GtinMatch:
    decision = (await session.execute(_DECISION, {"gtin": gtin14})).one_or_none()
    if decision is not None and decision.status == "disputed":
        return GtinMatch("disputed")
    if decision is not None and decision.status == "rejected":
        return GtinMatch("unknown")
    locked = decision.product_id if decision is not None and decision.status == "locked" else None
    row = (await session.execute(_ROWS, {"gtin": gtin14, "locked": locked})).one_or_none()
    if row is None:
        return GtinMatch("unknown")
    return GtinMatch("found", product_id=row.product_id, package_id=row.package_id)


async def find_product_by_gtin(session: AsyncSession, gtin14: str) -> UUID | None:
    return (await resolve_gtin(session, gtin14)).product_id
