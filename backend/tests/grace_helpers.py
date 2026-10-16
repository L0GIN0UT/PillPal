"""Helpers for the account-deletion suites (ADR 0010): request, ticket, restore, job."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import TYPE_CHECKING, Any

from httpx import AsyncClient, Response
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import User, last_code, outbox

if TYPE_CHECKING:
    from app.jobs.account_erasure import ErasureReport


def app_of(client: AsyncClient) -> Any:
    return client._transport.app  # type: ignore[attr-defined]


async def request_deletion(
    client: AsyncClient, user: User, password: str | None = None
) -> Response:
    body = {"password": user.password if password is None else password}
    return await client.request("DELETE", "/v1/me", json=body, headers=user.headers)


async def login(client: AsyncClient, email: str, password: str, device: str | None = None) -> Any:
    headers = {"X-Device-ID": device} if device else {}
    return await client.post(
        "/v1/auth/login", json={"email": email, "password": password}, headers=headers
    )


async def pending_login(client: AsyncClient, user: User) -> tuple[str, str]:
    """Log in to a pending account: ``(restore ticket, mailed one-time code)``."""
    resp = await login(client, user.email, user.password)
    assert resp.status_code == 403, resp.text
    error = resp.json()["error"]
    assert error["code"] == "account_pending_deletion"
    return error["details"]["restore_ticket"], last_code(client, user.email, "restore_account")


async def restore(
    client: AsyncClient, ticket: str, code: str | None, device: str | None = None
) -> Response:
    body: dict[str, Any] = {"restore_ticket": ticket}
    if code is not None:
        body["code"] = code
    headers = {"X-Device-ID": device} if device else {}
    return await client.post("/v1/auth/restore", json=body, headers=headers)


async def delete_and_restore(client: AsyncClient, user: User) -> User:
    """Request deletion, then restore with ticket and code; returns the user with fresh tokens."""
    assert (await request_deletion(client, user)).status_code == 204
    ticket, code = await pending_login(client, user)
    resp = await restore(client, ticket, code)
    assert resp.status_code == 200, resp.text
    tokens = resp.json()
    return User(
        id=user.id,
        email=user.email,
        password=user.password,
        access_token=tokens["access_token"],
        refresh_token=tokens["refresh_token"],
        self_profile_id=user.self_profile_id,
    )


async def run_erase_job(client: AsyncClient, now: datetime | None = None) -> ErasureReport:
    from app.jobs.account_erasure import erase_expired_accounts

    app = app_of(client)
    return await erase_expired_accounts(
        app.state.sessionmaker, app.state.settings, now=now or datetime.now(UTC)
    )


def sent_to(client: AsyncClient, email: str, purpose: str) -> list[Any]:
    return [m for m in outbox(client) if m.to == email.lower() and m.purpose == purpose]


async def scalar(engine: AsyncEngine, sql: str, **params: Any) -> Any:
    async with engine.connect() as conn:
        return (await conn.execute(text(sql), params)).scalar_one()


async def count(engine: AsyncEngine, table: str, where: str = "true", **params: Any) -> int:
    return int(
        await scalar(engine, f"SELECT count(*) FROM {table} WHERE {where}", **params)  # noqa: S608
    )


def uid(value: str) -> uuid.UUID:
    return uuid.UUID(value)


async def delete_and_erase(client: AsyncClient, user: User, password: str | None = None) -> None:
    """Request deletion, let the grace period pass on a shifted clock, run the erase job."""
    assert (await request_deletion(client, user, password)).status_code == 204
    report = await run_erase_job(client, datetime.now(UTC) + timedelta(days=31))
    assert uuid.UUID(user.id) in report.erased_ids


async def run_retention(client: AsyncClient, now: datetime) -> Any:
    from app.jobs.retention import cleanup_retention

    app = app_of(client)
    return await cleanup_retention(app.state.sessionmaker, app.state.settings, now=now)


def in_days(days: float) -> datetime:
    return datetime.now(UTC) + timedelta(days=days)
