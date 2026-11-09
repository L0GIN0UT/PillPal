"""POST /v1/gtins/lookup."""

from __future__ import annotations

from fastapi import APIRouter, Request
from sqlalchemy.ext.asyncio import AsyncSession

from catalog.api.guards import PUBLIC_DEPENDENCIES
from catalog.db.reads import run_read
from catalog.schemas.cards import GtinLookupRequest, GtinLookupResponse
from catalog.services.cards import lookup_gtin

router = APIRouter(prefix="/v1/gtins", tags=["gtins"], dependencies=PUBLIC_DEPENDENCIES)


@router.post("/lookup")
async def lookup(body: GtinLookupRequest, request: Request) -> GtinLookupResponse:
    """The product behind a GTIN: found, unknown, restricted or disputed (ADR 0014)."""

    async def work(session: AsyncSession) -> GtinLookupResponse:
        return await lookup_gtin(session, body.gtin)

    return await run_read(request, work)
