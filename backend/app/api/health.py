"""Liveness and readiness probes."""

from __future__ import annotations

import asyncio

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from redis.asyncio import Redis
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.errors import error_body
from app.observability import get_logger

router = APIRouter(tags=["health"])
_log = get_logger("pillpal.health")
CHECK_TIMEOUT_SECONDS = 2.0


@router.get("/healthz")
async def healthz() -> dict[str, str]:
    """Liveness: the process is up. Does not touch dependencies."""
    return {"status": "ok"}


async def _check_db(engine: AsyncEngine) -> None:
    async with engine.connect() as conn:
        await conn.execute(text("SELECT 1"))


async def _check_redis(redis: Redis) -> None:
    await redis.ping()


@router.get("/readyz", response_model=None)
async def readyz(request: Request) -> dict[str, object] | JSONResponse:
    """Readiness: database and Redis are reachable."""
    checks = {
        "database": _check_db(request.app.state.engine),
        "redis": _check_redis(request.app.state.redis),
    }
    results: dict[str, str] = {}
    for name, coro in checks.items():
        try:
            await asyncio.wait_for(coro, timeout=CHECK_TIMEOUT_SECONDS)
            results[name] = "ok"
        except Exception as exc:
            _log.warning("readiness_check_failed", check=name, exc_type=type(exc).__name__)
            results[name] = "unavailable"
    failed = [name for name, state in results.items() if state != "ok"]
    if failed:
        return JSONResponse(
            error_body("not_ready", f"Unavailable: {', '.join(failed)}"), status_code=503
        )
    return {"status": "ok", "checks": results}
