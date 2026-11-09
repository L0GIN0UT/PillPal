"""PUT /internal/v1/regions/{region}/gtin-confirmations: the regions' aggregates (ADR 0014).

Served by the private app only (``catalog.private_app``); the public proxy never routes it.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, Request

from catalog.api.service_auth import INGEST_DEPENDENCIES, require_ingest, token_region
from catalog.config import Settings, TokenEntry
from catalog.errors import AppError
from catalog.schemas.ingest import IngestResult, Region, SnapshotPage
from catalog.services.ingest import ingest_page

router = APIRouter(prefix="/internal/v1", tags=["internal"], dependencies=INGEST_DEPENDENCIES)


@router.put("/regions/{region}/gtin-confirmations")
async def put_gtin_confirmations(
    region: Region,
    body: SnapshotPage,
    request: Request,
    token: Annotated[TokenEntry, Depends(require_ingest)],
) -> IngestResult:
    """One page of a region's snapshot; the region's rows are swapped on the ``complete`` page."""
    if token_region(token) != region:
        raise AppError(403, "forbidden", "This token does not speak for that region")
    settings: Settings = request.app.state.settings
    async with request.app.state.sessionmaker() as session, session.begin():
        return await ingest_page(session, settings, region, body, datetime.now(UTC))
