"""Read side of the admin tools: open disputes with their candidates, and import runs."""

from __future__ import annotations

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from catalog.schemas.admin import (
    Dispute,
    DisputeCandidate,
    DisputePage,
    ImportRunItem,
    ImportRunPage,
)

_DISPUTES = text(
    "SELECT gtin, decided_at FROM catalog.gtin_link_decisions "
    "WHERE status = 'disputed' AND gtin > :after ORDER BY gtin LIMIT :limit"
)
_CANDIDATES = text(
    """
SELECT c.gtin, c.product_id, p.brand_name, sum(c.confirmations)::int AS total
  FROM catalog.gtin_link_candidates c
  JOIN catalog.products p ON p.id = c.product_id
 WHERE c.gtin = ANY(:gtins)
 GROUP BY c.gtin, c.product_id, p.brand_name
 ORDER BY c.gtin, total DESC, c.product_id
"""
)
_OFFICIAL = text(
    """
SELECT DISTINCT ON (g.gtin) g.gtin, pk.product_id
  FROM catalog.gtins g
  JOIN catalog.packages pk ON pk.id = g.package_id
  JOIN catalog.products p ON p.id = pk.product_id
 WHERE g.gtin = ANY(:gtins) AND g.origin = 'source' AND g.withdrawn_at IS NULL
   AND pk.withdrawn_at IS NULL AND p.withdrawn_at IS NULL
 ORDER BY g.gtin, g.source, pk.id
"""
)
_RUNS = text(
    "SELECT id, source, source_version, status, started_at, finished_at, counts, error_code "
    "FROM catalog.import_runs WHERE source <> 'consensus' "  # the synthetic carrier run
    "ORDER BY started_at DESC, id LIMIT :limit"
)


async def list_disputes(session: AsyncSession, after: str, limit: int) -> DisputePage:
    rows = (await session.execute(_DISPUTES, {"after": after, "limit": limit + 1})).all()
    page = rows[:limit]
    gtins = [row.gtin for row in page]
    candidates: dict[str, list[DisputeCandidate]] = {g: [] for g in gtins}
    official = {}
    if gtins:
        for row in await session.execute(_CANDIDATES, {"gtins": gtins}):
            candidates[row.gtin].append(
                DisputeCandidate(
                    product_id=row.product_id, name=row.brand_name, confirmations=row.total
                )
            )
        official = {
            r.gtin: r.product_id for r in await session.execute(_OFFICIAL, {"gtins": gtins})
        }
    items = [
        Dispute(
            gtin=row.gtin,
            decided_at=row.decided_at,
            official_product_id=official.get(row.gtin),
            candidates=candidates[row.gtin],
        )
        for row in page
    ]
    return DisputePage(items=items, next_after=page[-1].gtin if len(rows) > limit else None)


async def list_import_runs(session: AsyncSession, limit: int) -> ImportRunPage:
    rows = (await session.execute(_RUNS, {"limit": limit})).all()
    return ImportRunPage(
        items=[
            ImportRunItem(
                id=r.id,
                source=r.source,
                source_version=r.source_version,
                status=r.status,
                started_at=r.started_at,
                finished_at=r.finished_at,
                counts=r.counts,
                error_code=r.error_code,
            )
            for r in rows
        ]
    )
