"""The private app: admin and ingest endpoints on their own listener (ADR 0011 section 4).

Run it on an address the public reverse proxy never routes to, for example
``uvicorn catalog.private_app:app --host 0.0.0.0 --port 8001 --no-access-log`` inside the compose
network. The public app (``catalog.main``) has no route under ``/admin`` or ``/internal``; a test
asserts that. Both apps share one database and one image.
"""

from __future__ import annotations

from functools import lru_cache

from fastapi import FastAPI

from catalog.api import admin, health, internal
from catalog.config import Settings
from catalog.main import build_app


def create_private_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings()
    return build_app(
        settings,
        title="PillPal Catalog (private)",
        description="Regional ingest and admin tools. Never exposed to the internet.",
        routers=[health.router, internal.router, admin.router],
        body_max_bytes=settings.ingest_body_max_bytes,
    )


@lru_cache(maxsize=1)
def _default_app() -> FastAPI:
    return create_private_app()


def __getattr__(name: str) -> FastAPI:
    # Lazy, like ``catalog.main``: importing the module needs no production environment.
    if name == "app":
        return _default_app()
    raise AttributeError(name)
