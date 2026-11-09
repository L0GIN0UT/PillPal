"""Async engine / session factory."""

from __future__ import annotations

from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from catalog.config import Settings


def create_engine(settings: Settings) -> AsyncEngine:
    return create_async_engine(
        settings.database_url,
        pool_size=settings.db_pool_size,
        pool_pre_ping=True,
        # Never echo statements: bound parameters would carry what people searched for.
        echo=False,
        # Errors would otherwise quote the bound values (search strings, catalog text).
        hide_parameters=True,
        # Fail fast instead of hanging requests when the database is unreachable.
        connect_args={"timeout": 5, "command_timeout": 30},
    )


def create_sessionmaker(engine: AsyncEngine) -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(engine, expire_on_commit=False, autoflush=False)
