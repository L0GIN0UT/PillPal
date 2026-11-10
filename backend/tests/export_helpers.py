"""Helpers of the data export suites (ADR 0016 section 8): requests, the builder and raw rows."""

from __future__ import annotations

import io
import uuid
import zipfile
from datetime import datetime
from typing import Any

from httpx import AsyncClient, Response
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.config import Settings
from app.jobs.data_exports import ExportBuildReport, build_data_exports
from tests.grace_helpers import login
from tests.helpers import User

EXPORT_URL = "/v1/me/export"


def with_token(user: User, access_token: str) -> User:
    """The same account with another session's access token."""
    return User(
        id=user.id,
        email=user.email,
        password=user.password,
        access_token=access_token,
        refresh_token=user.refresh_token,
        self_profile_id=user.self_profile_id,
    )


async def second_session(client: AsyncClient, user: User) -> User:
    """A new login of the account: another refresh family, so another ``sid``."""
    resp = await login(client, user.email, user.password, device="second-phone")
    assert resp.status_code == 200, resp.text
    return with_token(user, resp.json()["access_token"])


async def request_export(
    client: AsyncClient, user: User, password: str | None = None, **headers: str
) -> Response:
    body = {"password": user.password if password is None else password}
    return await client.post(EXPORT_URL, json=body, headers={**user.headers, **headers})


async def export_status(client: AsyncClient, user: User, export_id: str) -> Response:
    return await client.get(f"{EXPORT_URL}/{export_id}", headers=user.headers)


async def download_export(
    client: AsyncClient, user: User, export_id: str, **headers: str
) -> Response:
    return await client.post(
        f"{EXPORT_URL}/{export_id}/download", headers={**user.headers, **headers}
    )


async def run_builder(
    maker: async_sessionmaker[AsyncSession], settings: Settings, now: datetime
) -> ExportBuildReport:
    return await build_data_exports(maker, settings, now=lambda: now)


async def requested_and_built(
    client: AsyncClient,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    user: User,
    now: datetime,
) -> str:
    """Request an export, let the builder run, return the (ready) export id."""
    resp = await request_export(client, user)
    assert resp.status_code == 202, resp.text
    export_id = str(resp.json()["id"])
    report = await run_builder(maker, settings, now)
    assert report.built >= 1, report
    return export_id


def zip_members(content: bytes) -> dict[str, bytes]:
    with zipfile.ZipFile(io.BytesIO(content)) as archive:
        return {name: archive.read(name) for name in archive.namelist()}


async def insert_export(
    engine: AsyncEngine,
    user_id: str,
    *,
    status: str = "queued",
    family_id: uuid.UUID | None = None,
    requested_at: datetime,
    lease_until: datetime | None = None,
    ready_at: datetime | None = None,
    expires_at: datetime | None = None,
    error_code: str | None = None,
    archive: bytes | None = None,
) -> uuid.UUID:
    export_id = uuid.uuid4()
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO data_exports (id, user_id, family_id, status, error_code, "
                "requested_at, lease_until, ready_at, expires_at, size_bytes, archive) "
                "VALUES (:id, :u, :f, :s, :e, :r, :l, :ra, :x, :sz, :a)"
            ),
            {
                "id": export_id,
                "u": uuid.UUID(user_id),
                "f": family_id or uuid.uuid4(),
                "s": status,
                "e": error_code,
                "r": requested_at,
                "l": lease_until,
                "ra": ready_at,
                "x": expires_at,
                "sz": len(archive) if archive else None,
                "a": archive,
            },
        )
    return export_id


async def export_row(engine: AsyncEngine, export_id: str | uuid.UUID) -> Any:
    async with engine.connect() as conn:
        result = await conn.execute(
            text(
                "SELECT status, error_code, family_id, archive, size_bytes, lease_until, "
                "ready_at, expires_at FROM data_exports WHERE id = :id"
            ),
            {"id": uuid.UUID(str(export_id))},
        )
        return result.first()
