"""A real PostgreSQL error through the real application reaches the tracker without its DETAIL."""

from __future__ import annotations

import httpx
import sentry_sdk
from sqlalchemy import text

from app.error_tracking import init_error_tracking
from app.main import create_app
from tests.conftest import make_settings
from tests.test_error_tracking import DSN, CapturingTransport

NEEDLE = "needle-medication-500mg"


async def test_a_database_violation_detail_is_not_sent(migrated_db: str) -> None:
    transport = CapturingTransport()
    settings = make_settings(sentry_dsn=DSN)
    app = create_app(settings)
    init_error_tracking(settings, transport=transport)

    @app.post("/v1/db-boom")
    async def db_boom() -> None:
        # asyncpg's UniqueViolationError carries "Key (v)=(<value>) already exists." as DETAIL.
        async with app.state.engine.begin() as conn:
            await conn.execute(text("CREATE TEMP TABLE leak (v text UNIQUE)"))
            for _ in range(2):
                await conn.execute(text("INSERT INTO leak VALUES (:v)"), {"v": NEEDLE})

    try:
        async with (
            app.router.lifespan_context(app),
            httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="http://testserver"
            ) as client,
        ):
            response = await client.post("/v1/db-boom")
    finally:
        sentry_sdk.get_global_scope().set_client(None)

    assert response.status_code == 500
    assert len(transport.payloads) == 1
    assert NEEDLE not in transport.raw
    assert "IntegrityError" in transport.raw
