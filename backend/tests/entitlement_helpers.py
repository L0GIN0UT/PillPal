"""Helpers of the entitlement suites (ADR 0018): rows and audit rows inserted with SQL."""

from __future__ import annotations

import io
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.admin.cli import run_admin
from app.services.admin_audit import Operator
from tests.conftest import make_settings


async def insert_entitlement(
    engine: AsyncEngine,
    user_id: str,
    kind: str = "ads_removed",
    source: str = "admin_grant",
    *,
    granted_at: datetime | None = None,
    expires_at: datetime | None = None,
    revoked_at: datetime | None = None,
) -> uuid.UUID:
    row_id = uuid.uuid4()
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO entitlements (id, user_id, kind, source, granted_at, expires_at, "
                "revoked_at) VALUES (:id, :u, :k, :s, :g, :e, :r)"
            ),
            {
                "id": row_id,
                "u": uuid.UUID(user_id),
                "k": kind,
                "s": source,
                "g": granted_at or datetime.now(UTC) - timedelta(days=1),
                "e": expires_at,
                "r": revoked_at,
            },
        )
    return row_id


async def insert_audit(
    engine: AsyncEngine,
    target_user_id: str | None,
    object_id: uuid.UUID | None,
    *,
    at: datetime | None = None,
    actor: str = "synthetic-operator",
) -> uuid.UUID:
    row_id = uuid.uuid4()
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO admin_audit (id, at, actor, action, target_user_id, object_id, kind, "
                "os_user, host) VALUES (:id, :at, :actor, 'entitlement_grant', :t, :o, "
                "'ads_removed', 'synthetic-os-user', 'synthetic-host')"
            ),
            {
                "id": row_id,
                "at": at or datetime.now(UTC),
                "actor": actor,
                "t": uuid.UUID(target_user_id) if target_user_id else None,
                "o": object_id,
            },
        )
    return row_id


async def rows(engine: AsyncEngine, sql: str, **params: Any) -> list[dict[str, Any]]:
    async with engine.connect() as conn:
        return [dict(r) for r in (await conn.execute(text(sql), params)).mappings()]


OPERATOR = Operator("synthetic-operator", "synthetic-os-user", "synthetic-host")


@dataclass
class CliRun:
    code: int
    out: str
    err: str


async def run_cli(*argv: str, stdin: str = "", operator: Operator | None = OPERATOR) -> CliRun:
    """Run ``python -m app.admin`` in process against the test database."""
    out, err = io.StringIO(), io.StringIO()
    code = await run_admin(
        argv,
        stdin=io.StringIO(stdin),
        settings=make_settings(),
        stdout=out,
        stderr=err,
        operator=operator,
    )
    return CliRun(code, out.getvalue(), err.getvalue())
