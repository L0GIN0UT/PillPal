"""POST /v1/search."""

from __future__ import annotations

from fastapi import APIRouter, Request
from sqlalchemy.ext.asyncio import AsyncSession

from catalog.api.guards import LOOKUP_DEPENDENCIES
from catalog.config import Settings
from catalog.db.reads import run_read
from catalog.schemas.search import SearchRequest, SearchResponse
from catalog.services.search import search

router = APIRouter(prefix="/v1", tags=["search"], dependencies=LOOKUP_DEPENDENCIES)


@router.post("/search")
async def search_catalog(body: SearchRequest, request: Request) -> SearchResponse:
    """Products (or substances) by brand, INN or barcode digits; own market first (D6)."""
    settings: Settings = request.app.state.settings

    async def work(session: AsyncSession) -> SearchResponse:
        return await search(session, body, settings)

    return await run_read(request, work)
