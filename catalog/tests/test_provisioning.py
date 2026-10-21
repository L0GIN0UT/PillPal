"""``infra/catalog-db/init.sh`` against a real PostgreSQL: a dedicated role owns the catalog
database, cannot reach the backend's, and statement logging is off for it."""

from __future__ import annotations

import os
import subprocess
from collections.abc import AsyncIterator
from urllib.parse import quote

import asyncpg
import pytest
import pytest_asyncio
from sqlalchemy.engine import make_url

from tests.conftest import TEST_DATABASE_URL
from tests.helpers import CATALOG_DIR, run_migrations

SCRIPT = CATALOG_DIR.parent / "infra" / "catalog-db" / "init.sh"
ROLE, CATALOG_DB, BACKEND_DB = "catalog_prov_role", "catalog_prov_db", "catalog_prov_backend"
ROLE_PASSWORD = "prov-pass-with-'quote\"-and-$dollar"


def _admin() -> tuple[str, str, str, str]:
    url = make_url(TEST_DATABASE_URL)
    return (url.host or "localhost", str(url.port or 5432), url.username or "", url.password or "")


def _run_script() -> None:
    host, port, user, password = _admin()
    env = {
        **os.environ,
        "POSTGRES_HOST": host,
        "PGPORT": port,
        "POSTGRES_USER": user,
        "PGPASSWORD": password,
        "POSTGRES_DB": BACKEND_DB,
        "CATALOG_POSTGRES_DB": CATALOG_DB,
        "CATALOG_DB_USER": ROLE,
        "CATALOG_DB_PASSWORD": ROLE_PASSWORD,
    }
    subprocess.run(["sh", str(SCRIPT)], env=env, check=True, capture_output=True, timeout=60)  # noqa: S603, S607


async def _admin_connect(database: str = "postgres") -> asyncpg.Connection:
    host, port, user, password = _admin()
    return await asyncpg.connect(
        host=host, port=int(port), user=user, password=password, database=database
    )


async def _drop_everything() -> None:
    conn = await _admin_connect()
    try:
        for db in (CATALOG_DB, BACKEND_DB):
            await conn.execute(f'DROP DATABASE IF EXISTS "{db}" WITH (FORCE)')
        await conn.execute(f'DROP ROLE IF EXISTS "{ROLE}"')
    finally:
        await conn.close()


@pytest_asyncio.fixture
async def provisioned() -> AsyncIterator[None]:
    await _drop_everything()
    conn = await _admin_connect()
    try:
        await conn.execute(f'CREATE DATABASE "{BACKEND_DB}"')  # stands in for the backend's DB
    finally:
        await conn.close()
    _run_script()
    try:
        yield
    finally:
        await _drop_everything()


async def _as_role(database: str) -> asyncpg.Connection:
    host, port, _, _ = _admin()
    return await asyncpg.connect(
        host=host, port=int(port), user=ROLE, password=ROLE_PASSWORD, database=database
    )


async def test_role_is_not_a_superuser_and_owns_only_the_catalog_database(
    provisioned: None,
) -> None:
    conn = await _admin_connect()
    try:
        row = await conn.fetchrow(
            "SELECT rolsuper, rolcreatedb, rolcreaterole, rolcanlogin "
            "FROM pg_roles WHERE rolname = $1",
            ROLE,
        )
        owner = await conn.fetchval(
            "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = $1", CATALOG_DB
        )
    finally:
        await conn.close()
    assert dict(row) == {  # type: ignore[arg-type]
        "rolsuper": False,
        "rolcreatedb": False,
        "rolcreaterole": False,
        "rolcanlogin": True,
    }
    assert owner == ROLE


async def test_role_cannot_connect_to_the_backend_database(provisioned: None) -> None:
    with pytest.raises(asyncpg.InsufficientPrivilegeError):
        await _as_role(BACKEND_DB)


async def test_statement_logging_is_off_for_the_catalog_database(provisioned: None) -> None:
    conn = await _as_role(CATALOG_DB)
    try:
        settings = {
            name: await conn.fetchval("SELECT current_setting($1)", name)
            for name in (
                "log_statement",
                "log_min_duration_statement",
                "log_parameter_max_length_on_error",
            )
        }
    finally:
        await conn.close()
    assert settings == {
        "log_statement": "none",
        "log_min_duration_statement": "-1",
        "log_parameter_max_length_on_error": "0",
    }


async def test_script_is_idempotent_and_can_rotate_the_password(provisioned: None) -> None:
    _run_script()
    conn = await _as_role(CATALOG_DB)
    await conn.close()


async def test_migrations_run_as_the_unprivileged_role(provisioned: None) -> None:
    host, port, _, _ = _admin()
    url = f"postgresql+asyncpg://{ROLE}:{quote(ROLE_PASSWORD, safe='')}@{host}:{port}/{CATALOG_DB}"
    run_migrations(url, "head")
    conn = await _as_role(CATALOG_DB)
    try:
        assert await conn.fetchval("SELECT catalog.unaccent_immutable('é')") == "e"
    finally:
        await conn.close()
