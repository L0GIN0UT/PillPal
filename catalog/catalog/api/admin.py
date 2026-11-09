"""Admin endpoints (ADR 0014 section 5): disputes, resolving a GTIN, import runs.

Private app only. Every action is audited by the service with the token's label (no person).
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request

from catalog.api.service_auth import ADMIN_DEPENDENCIES, require_admin
from catalog.config import TokenEntry
from catalog.domain.gtin import GtinError, normalize
from catalog.errors import AppError
from catalog.schemas.admin import (
    DisputePage,
    ImportRunPage,
    ResolveRequest,
    ResolveResponse,
)
from catalog.services.decisions import DecisionError, resolve
from catalog.services.disputes import list_disputes, list_import_runs

router = APIRouter(prefix="/admin/v1", tags=["admin"], dependencies=ADMIN_DEPENDENCIES)

_AFTER = Query(default="", pattern=r"^[0-9]{0,14}$")


def _limit(request: Request, requested: int | None) -> int:
    cap: int = request.app.state.settings.admin_page_max
    return min(requested, cap) if requested else cap


@router.get("/disputes")
async def disputes(
    request: Request, after: str = _AFTER, limit: Annotated[int | None, Query(ge=1)] = None
) -> DisputePage:
    async with request.app.state.sessionmaker() as session, session.begin():
        return await list_disputes(session, after, _limit(request, limit))


@router.get("/import-runs")
async def import_runs(
    request: Request, limit: Annotated[int | None, Query(ge=1)] = None
) -> ImportRunPage:
    async with request.app.state.sessionmaker() as session, session.begin():
        return await list_import_runs(session, _limit(request, limit))


def shareable_gtin14(raw: str) -> str:
    """The 14-digit form of a shareable number; anything else is ``422 invalid_gtin``."""
    try:
        gtin = normalize(raw)
    except GtinError:
        raise AppError(422, "invalid_gtin", "Not a valid GTIN") from None
    if gtin.classification != "shareable":
        raise AppError(422, "invalid_gtin", "Not a valid GTIN")
    return gtin.gtin14


@router.post("/gtins/{gtin}:resolve")
async def resolve_gtin(
    gtin: str,
    body: ResolveRequest,
    request: Request,
    admin: Annotated[TokenEntry, Depends(require_admin)],
) -> ResolveResponse:
    number = shareable_gtin14(gtin)
    try:
        async with request.app.state.sessionmaker() as session, session.begin():
            decision = await resolve(session, number, body.action, body.product_id, admin.name)
    except DecisionError as exc:
        raise AppError(exc.status_code, exc.code, "The decision cannot be applied") from None
    return ResolveResponse(
        gtin=number,
        status=decision.status,
        product_id=decision.product_id,
        decided_by=decision.decided_by,
        reason_code=decision.reason_code,
    )
