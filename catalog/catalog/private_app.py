"""The private app: admin and ingest endpoints on their own listener (ADR 0011 section 4).

Run it on an address the public reverse proxy never routes to, for example
``uvicorn catalog.private_app:app --host 0.0.0.0 --port 8001 --no-access-log`` inside the compose
network. The public app (``catalog.main``) has no route under ``/admin`` or ``/internal``; a test
asserts that. Both apps share one database and one image.
"""

from __future__ import annotations

from functools import lru_cache

from fastapi import FastAPI
from redis.asyncio import Redis

from catalog.api import admin, health, internal
from catalog.config import Settings
from catalog.main import build_app
from catalog.ratelimit import RateLimiter
from catalog.services.maintenance import maintenance_loop


def _private_limiter(redis: Redis, settings: Settings) -> RateLimiter:
    # Its own bucket kind and a much lower per-IP limit than the public listener.
    return RateLimiter(
        redis, settings, ip_bucket="private-ip", ip_limit=settings.private_rate_limit_ip_max
    )


def create_private_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings()
    settings.require_service_tokens()
    return build_app(
        settings,
        title="PillPal Catalog (private)",
        description="Regional ingest and admin tools. Never exposed to the internet.",
        routers=[health.router, internal.router, admin.router],
        body_max_bytes=settings.ingest_body_max_bytes,
        rate_limiter_factory=_private_limiter,
        background=[maintenance_loop],
        expose_docs=False,  # no /docs and no /openapi.json on a listener of secrets
    )


@lru_cache(maxsize=1)
def _default_app() -> FastAPI:
    return create_private_app()


def __getattr__(name: str) -> FastAPI:
    # Lazy, like ``catalog.main``: importing the module needs no production environment.
    if name == "app":
        return _default_app()
    raise AttributeError(name)
