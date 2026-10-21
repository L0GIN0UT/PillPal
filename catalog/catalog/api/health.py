"""Liveness and readiness probes."""

from __future__ import annotations

import asyncio

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from sqlalchemy import text

from catalog.errors import error_body
from catalog.observability import get_logger

router = APIRouter(tags=["health"])
_log = get_logger("catalog.health")
CHECK_TIMEOUT_SECONDS = 2.0


@router.get("/healthz")
async def healthz() -> dict[str, str]:
    """Liveness: the process is up. Does not touch dependencies."""
    return {"status": "ok"}


async def _ping_database(request: Request) -> None:
    async with request.app.state.engine.connect() as conn:
        await conn.execute(text("SELECT 1"))


@router.get("/readyz", response_model=None)
async def readyz(request: Request) -> dict[str, object] | JSONResponse:
    """Readiness: the database answers. Redis is not checked, rate limiting fails open."""
    try:
        await asyncio.wait_for(_ping_database(request), timeout=CHECK_TIMEOUT_SECONDS)
    except Exception as exc:
        _log.warning("readiness_check_failed", check="database", exc_type=type(exc).__name__)
        return JSONResponse(error_body("not_ready", "Unavailable: database"), status_code=503)
    return {"status": "ok", "checks": {"database": "ok"}}
