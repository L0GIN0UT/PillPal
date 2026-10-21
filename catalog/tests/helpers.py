"""Test helpers: Alembic runner."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

from alembic.config import Config

from alembic import command

CATALOG_DIR = Path(__file__).resolve().parent.parent


def alembic_config(url: str) -> Config:
    cfg = Config(str(CATALOG_DIR / "alembic.ini"))
    cfg.set_main_option("script_location", str(CATALOG_DIR / "alembic"))
    cfg.set_main_option("sqlalchemy.url", url.replace("%", "%%"))  # configparser interpolation
    # Do not let Alembic reconfigure (and silence) the logging that tests capture.
    cfg.attributes["configure_logger"] = False
    return cfg


def run_sync(fn: Any, *args: Any) -> Any:
    # Alembic's async env.py calls asyncio.run(); keep it off any running loop.
    with ThreadPoolExecutor(max_workers=1) as pool:
        return pool.submit(fn, *args).result()


def run_migrations(url: str, revision: str) -> None:
    run_sync(command.upgrade, alembic_config(url), revision)


def downgrade(url: str, revision: str) -> None:
    run_sync(command.downgrade, alembic_config(url), revision)
