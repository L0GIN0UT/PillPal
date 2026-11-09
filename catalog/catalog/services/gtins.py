"""Which product a GTIN belongs to (ADR 0014 section 4, docs/spec/gtin.md).

Precedence among the rows of one number: rows that are not withdrawn, then ``admin`` > ``source``
> ``consensus`` origin, then the source code and package id (deterministic). A ``disputed``
decision answers without a product; ``rejected`` answers unknown.
A ``locked`` decision returns its product directly, with the package that carries the number when
there is one. ``promoted`` relies on an invariant of the consensus code (4.7): promotion writes the
consensus ``gtins`` row, so the ordinary row lookup finds the product; this module does not read
``product_id`` of a ``promoted`` decision.
A withdrawn consensus row never answers: it is withdrawn when the link stops holding (a
dispute, a rejection, a drop to pending), so a stale row must not resurrect it.
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
   AND NOT (g.origin = 'consensus'
            AND (g.withdrawn_at IS NOT NULL OR pk.withdrawn_at IS NOT NULL))
 ORDER BY (g.withdrawn_at IS NOT NULL OR pk.withdrawn_at IS NOT NULL
              OR p.withdrawn_at IS NOT NULL),
          CASE g.origin WHEN 'admin' THEN 0 WHEN 'source' THEN 1 ELSE 2 END,
          g.source, pk.id
 LIMIT 1
"""
)


_LOCKED_PACKAGE = text(
    """
SELECT pk.id FROM catalog.gtins g
  JOIN catalog.packages pk ON pk.id = g.package_id
 WHERE g.gtin = :gtin AND pk.product_id = :product
 ORDER BY (g.withdrawn_at IS NOT NULL OR pk.withdrawn_at IS NOT NULL), g.source, pk.id
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
    if decision is not None and decision.status == "locked":
        package = (
            await session.execute(_LOCKED_PACKAGE, {"gtin": gtin14, "product": decision.product_id})
        ).scalar_one_or_none()
        return GtinMatch("found", product_id=decision.product_id, package_id=package)
    row = (await session.execute(_ROWS, {"gtin": gtin14})).one_or_none()
    if row is None:
        return GtinMatch("unknown")
    return GtinMatch("found", product_id=row.product_id, package_id=row.package_id)


async def find_product_by_gtin(session: AsyncSession, gtin14: str) -> UUID | None:
    return (await resolve_gtin(session, gtin14)).product_id
