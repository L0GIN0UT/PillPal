"""Command-line entry points of the jobs, used until the ARQ scheduler exists (milestone 3.4)."""

from __future__ import annotations

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from app.jobs import account_erasure, retention
from app.jobs.cli import run_cli
from tests.grace_helpers import count, request_deletion
from tests.helpers import register


async def test_the_erase_cli_erases_due_accounts_and_exits_zero(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    assert (await request_deletion(client, user)).status_code == 204
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "UPDATE users SET deletion_requested_at = now() - interval '40 days', "
                "erase_after = now() - interval '1 hour' WHERE id = :id"
            ),
            {"id": user.id},
        )

    code = await run_cli(account_erasure.erase_expired_accounts, Settings())

    assert code == 0
    assert await count(engine, "users", "id = :id", id=user.id) == 0


async def test_the_retention_cli_runs_and_exits_zero(client: AsyncClient) -> None:
    assert await run_cli(retention.cleanup_retention, Settings()) == 0


def test_the_modules_are_runnable_with_dash_m() -> None:
    assert callable(account_erasure.main)
    assert callable(retention.main)
