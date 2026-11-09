"""Application factory. ASGI entry point: ``catalog.main:app``."""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Awaitable, Callable, Sequence
from contextlib import asynccontextmanager
from functools import lru_cache

from fastapi import APIRouter, FastAPI
from redis.asyncio import Redis

from catalog.api import gtins, health, products, search, sources
from catalog.bodylimit import BodyLimitMiddleware
from catalog.config import Settings
from catalog.db.session import create_engine, create_sessionmaker
from catalog.errors import install_error_handlers
from catalog.observability import RequestContextMiddleware, configure_logging, get_logger
from catalog.ratelimit import RateLimiter

_log = get_logger("catalog.app")


def build_app(
    settings: Settings,
    *,
    title: str,
    description: str,
    routers: Sequence[APIRouter],
    body_max_bytes: int,
    rate_limiter_factory: Callable[[Redis, Settings], RateLimiter] = RateLimiter,
    background: Sequence[Callable[[FastAPI], Awaitable[None]]] = (),
    expose_docs: bool = True,
) -> FastAPI:
    """The shared skeleton of the public and the private app: lifespan, errors, middlewares."""
    configure_logging(settings.log_level)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        engine = create_engine(settings)
        redis = Redis.from_url(
            settings.redis_url,
            socket_connect_timeout=1,
            socket_timeout=1,
            retry_on_timeout=False,
            health_check_interval=30,
        )
        app.state.engine = engine
        app.state.sessionmaker = create_sessionmaker(engine)
        app.state.redis = redis
        app.state.rate_limiter = rate_limiter_factory(redis, settings)
        tasks = [asyncio.ensure_future(job(app)) for job in background]
        _log.info("startup", environment=settings.environment)
        try:
            yield
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            await redis.aclose()
            await engine.dispose()
            _log.info("shutdown")

    app = FastAPI(
        title=title,
        version="0.1.0",
        description=description,
        lifespan=lifespan,
        docs_url="/docs" if expose_docs else None,
        redoc_url="/redoc" if expose_docs else None,
        openapi_url="/openapi.json" if expose_docs else None,
    )
    app.state.settings = settings
    install_error_handlers(app)
    # No CORS: the app is a native client, and a browser has no business here.
    # Added last = outermost: request id and access log wrap everything.
    app.add_middleware(BodyLimitMiddleware, max_bytes=body_max_bytes)
    app.add_middleware(RequestContextMiddleware)
    for router in routers:
        app.include_router(router)
    return app


def create_app(settings: Settings | None = None) -> FastAPI:
    """The public app: search, lookup, cards, sources. No admin, no ingest (ADR 0011 section 4)."""
    settings = settings or Settings()
    return build_app(
        settings,
        title="PillPal Catalog",
        description="Global medicine catalog: public reference data, no personal data.",
        routers=[health.router, search.router, gtins.router, products.router, sources.router],
        body_max_bytes=settings.request_body_max_bytes,
    )


@lru_cache(maxsize=1)
def _default_app() -> FastAPI:
    return create_app()


def __getattr__(name: str) -> FastAPI:
    # Lazy module attribute so importing catalog.main (tests, tooling) does not require
    # production environment variables.
    if name == "app":
        return _default_app()
    raise AttributeError(name)
