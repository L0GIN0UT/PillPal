"""GET /v1/sources: the attribution the app shows in Settings -> About."""

from __future__ import annotations

from fastapi import APIRouter, Request, Response
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from catalog.api.guards import PUBLIC_DEPENDENCIES
from catalog.db.reads import run_read
from catalog.schemas.cards import SourceOut

router = APIRouter(prefix="/v1", tags=["sources"], dependencies=PUBLIC_DEPENDENCIES)

# Static reference data that changes with a release: caches may keep it for an hour.
SOURCES_CACHE_CONTROL = "public, max-age=3600"

_SOURCES = text(
    "SELECT code, name, license, attribution, url FROM catalog.sources WHERE enabled ORDER BY code"
)


@router.get("/sources")
async def list_sources(request: Request, response: Response) -> list[SourceOut]:
    """Every enabled source with its license note and the attribution text."""
    response.headers["Cache-Control"] = SOURCES_CACHE_CONTROL

    async def work(session: AsyncSession) -> list[SourceOut]:
        rows = (await session.execute(_SOURCES)).mappings().all()
        return [SourceOut.model_validate(dict(r)) for r in rows]

    return await run_read(request, work)
