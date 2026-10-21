"""The catalog holds no personal data by construction (ADR 0011): it never imports the regional
backend, and its schema has no place to put an account, a device or a token."""

from __future__ import annotations

import ast
import re

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import CATALOG_DIR

FORBIDDEN_NAME = re.compile(
    r"email|user_id|userid|device|token|password|ip_address|client_ip|phone"
    r"|install|session|account|query|search_log"
    r"|(?<![a-z])ip(?![a-z])",
    re.IGNORECASE,
)
SYSTEM_SCHEMAS = ("pg_catalog", "information_schema", "pg_toast")


def _imported_roots(path: str) -> set[str]:
    tree = ast.parse(open(path, encoding="utf-8").read())  # noqa: SIM115
    roots: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            roots.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            roots.add(node.module.split(".")[0])
    return roots


def test_no_module_imports_the_regional_backend() -> None:
    files = [
        *(CATALOG_DIR / "catalog").rglob("*.py"),
        *(CATALOG_DIR / "alembic").rglob("*.py"),
    ]
    assert len(files) > 5
    offenders = {str(f.relative_to(CATALOG_DIR)) for f in files if "app" in _imported_roots(str(f))}
    assert offenders == set()


def test_the_scan_sees_a_backend_import(tmp_path: object) -> None:
    # The checker itself must be able to fail.
    probe = tmp_path / "m.py"  # type: ignore[operator]
    probe.write_text("from app.db import models\nimport app.config\n")
    assert _imported_roots(str(probe)) == {"app"}


async def test_schema_has_no_personal_data_names(engine: AsyncEngine) -> None:
    async with engine.connect() as conn:
        rows = (
            await conn.execute(
                text(
                    "SELECT table_schema, table_name, column_name FROM information_schema.columns "
                    "WHERE table_schema <> ALL(:system) AND table_schema NOT LIKE 'pg_%'"
                ),
                {"system": list(SYSTEM_SCHEMAS)},
            )
        ).all()
    assert rows, "introspection found no columns at all"
    offenders = [
        (schema, table, column)
        for schema, table, column in rows
        if FORBIDDEN_NAME.search(table) or FORBIDDEN_NAME.search(column)
    ]
    assert offenders == []


def test_forbidden_name_pattern_catches_the_obvious() -> None:
    for name in (
        "email",
        "owner_email",
        "user_id",
        "device_id",
        "refresh_token",
        "Password",
        "install_id",
        "session",
        "account_id",
        "query_text",
        "search_log",
        "ip",
        "ip_hash",
    ):
        assert FORBIDDEN_NAME.search(name)
    for name in ("brand_name", "gtin", "source_key", "description", "recipe"):
        assert not FORBIDDEN_NAME.search(name)
