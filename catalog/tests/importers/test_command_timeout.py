"""Statement timeouts: the API fails fast, a long import gets its own, longer limit."""

from __future__ import annotations

import asyncio
from pathlib import Path

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from catalog.config import Settings
from catalog.db import session as db_session
from catalog.importers import cli
from tests.conftest import make_settings
from tests.importers.support import V1


async def _sleep_on(engine: AsyncEngine, seconds: float) -> None:
    try:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT pg_sleep(:s)"), {"s": seconds})
    finally:
        await engine.dispose()


async def test_a_statement_longer_than_the_command_timeout_is_cancelled() -> None:
    engine = db_session.create_engine(make_settings(), command_timeout=0.2)

    with pytest.raises(TimeoutError):
        await _sleep_on(engine, 1)


async def test_a_statement_within_the_command_timeout_completes() -> None:
    await _sleep_on(db_session.create_engine(make_settings(), command_timeout=5), 0.3)


def test_the_importer_limit_defaults_far_above_the_api_limit() -> None:
    assert make_settings().importer_command_timeout_seconds > db_session.API_COMMAND_TIMEOUT_SECONDS


async def test_the_importer_cli_uses_the_importer_limit(
    clean_catalog: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    used: list[float] = []

    def recording(settings: Settings, *, command_timeout: float) -> AsyncEngine:
        used.append(command_timeout)
        return db_session.create_engine(settings, command_timeout=command_timeout)

    monkeypatch.setattr(cli, "create_engine", recording)
    settings = make_settings(importer_command_timeout_seconds=1234)

    code = await asyncio.to_thread(
        cli.main, ["run", "--source", "fixture", "--snapshot", str(Path(V1))], settings
    )

    assert code == 0
    assert used == [1234]
