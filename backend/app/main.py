"""Application factory. ASGI entry point: ``app.main:app``."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from functools import lru_cache

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from redis.asyncio import Redis

from app.api import auth, health, links, push, relatives, resources, sync
from app.config import STRICT_ENVIRONMENTS, Settings
from app.db.session import create_engine, create_sessionmaker
from app.email import EmailSender, InMemoryEmailSender, LoggingEmailSender
from app.email_smtp import smtp_sender_from_settings
from app.errors import install_error_handlers
from app.observability import RequestContextMiddleware, configure_logging, get_logger
from app.ratelimit import RateLimiter
from app.security import PasswordHasher, TokenService

_log = get_logger("pillpal.app")


def _email_sender(settings: Settings, injected: EmailSender | None) -> EmailSender:
    if injected is not None:
        return injected
    if settings.environment in STRICT_ENVIRONMENTS and settings.email_backend != "smtp":
        # The logging and in-memory senders drop every mail: users could never verify or reset.
        raise RuntimeError(
            f"ENVIRONMENT={settings.environment} requires EMAIL_BACKEND=smtp (with SMTP_HOST "
            "and SMTP_FROM); the log and memory senders are for dev/test"
        )
    if settings.email_backend == "smtp":
        return smtp_sender_from_settings(settings)
    if settings.email_backend == "memory":
        return InMemoryEmailSender()
    return LoggingEmailSender(log_codes=settings.log_email_codes)


def create_app(
    settings: Settings | None = None, *, email_sender: EmailSender | None = None
) -> FastAPI:
    settings = settings or Settings()
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
        app.state.rate_limiter = RateLimiter(redis, settings)
        _log.info("startup", region=settings.region, environment=settings.environment)
        try:
            yield
        finally:
            await redis.aclose()
            await engine.dispose()
            _log.info("shutdown")

    app = FastAPI(
        title="PillPal API",
        version="0.1.0",
        description=f"PillPal backend, data region `{settings.region}`.",
        lifespan=lifespan,
    )
    app.state.settings = settings
    app.state.tokens = TokenService(settings)
    app.state.hasher = PasswordHasher(settings)
    app.state.email_sender = _email_sender(settings, email_sender)

    install_error_handlers(app)
    if settings.cors_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=settings.cors_origins,
            allow_methods=["GET", "POST", "PATCH", "DELETE"],
            allow_headers=["Authorization", "Content-Type", "X-Device-ID", "X-Request-ID"],
            expose_headers=["X-Request-ID", "Retry-After"],
        )
    # Added last = outermost: request id and access log wrap everything.
    app.add_middleware(RequestContextMiddleware)

    app.include_router(health.router)
    app.include_router(auth.router)
    app.include_router(auth.me_router)
    app.include_router(resources.router)
    app.include_router(relatives.router)
    app.include_router(links.router)
    app.include_router(push.router)
    app.include_router(sync.router)
    return app


@lru_cache(maxsize=1)
def _default_app() -> FastAPI:
    return create_app()


def __getattr__(name: str) -> FastAPI:
    # Lazy module attribute so importing app.main (tests, tooling) does not
    # require production environment variables.
    if name == "app":
        return _default_app()
    raise AttributeError(name)
