"""One read-only transaction per public request, with the statement timeout applied.

The timeout is the backstop against pathological queries on an unauthenticated endpoint. It is
transaction-scoped (``set_config(..., true)``), so it never leaks to the pooled connection's next
user. A cancelled statement becomes ``503 catalog_timeout`` with a fixed message: the SQL text and
bound parameters (what the person searched for) never reach the response or the log.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable

from fastapi import Request
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncSession

from catalog.config import Settings
from catalog.errors import AppError
from catalog.observability import get_logger

# PostgreSQL error class 57 / query_canceled (statement_timeout).
QUERY_CANCELED_SQLSTATE = "57014"

_log = get_logger("catalog.reads")


def is_statement_timeout(exc: DBAPIError) -> bool:
    return getattr(exc.orig, "sqlstate", None) == QUERY_CANCELED_SQLSTATE


async def _apply_limits(session: AsyncSession, settings: Settings) -> None:
    await session.execute(text("SET TRANSACTION READ ONLY"))
    await session.execute(
        text(
            "SELECT set_config('statement_timeout', :ms, true), "
            "set_config('pg_trgm.word_similarity_threshold', :threshold, true)"
        ),
        {
            "ms": str(settings.search_statement_timeout_ms),
            "threshold": str(settings.search_trigram_threshold),
        },
    )


async def run_read[T](request: Request, work: Callable[[AsyncSession], Awaitable[T]]) -> T:
    settings: Settings = request.app.state.settings
    try:
        async with request.app.state.sessionmaker() as session, session.begin():
            await _apply_limits(session, settings)
            return await work(session)
    except DBAPIError as exc:
        if not is_statement_timeout(exc):
            raise
        _log.warning("statement_timeout")
        raise AppError(503, "catalog_timeout", "The catalog is busy, try again") from None
