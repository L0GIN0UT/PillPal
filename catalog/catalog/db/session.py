"""Async engine / session factory."""

from __future__ import annotations

from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from catalog.config import Settings

# Requests fail fast instead of hanging when the database is slow or unreachable.
API_COMMAND_TIMEOUT_SECONDS = 30.0


def create_engine(
    settings: Settings, *, command_timeout: float = API_COMMAND_TIMEOUT_SECONDS
) -> AsyncEngine:
    """``command_timeout`` caps one statement; the importer passes its own, longer limit
    (a full ESKLP load has statements that run for minutes on a small server)."""
    return create_async_engine(
        settings.database_url,
        pool_size=settings.db_pool_size,
        pool_pre_ping=True,
        # Never echo statements: bound parameters would carry what people searched for.
        echo=False,
        # Errors would otherwise quote the bound values (search strings, catalog text).
        hide_parameters=True,
        connect_args={"timeout": 5, "command_timeout": command_timeout},
    )


def create_sessionmaker(engine: AsyncEngine) -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(engine, expire_on_commit=False, autoflush=False)
