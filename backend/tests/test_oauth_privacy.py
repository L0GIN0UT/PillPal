"""OAuth data inventory, export, erasure and logs (ADR 0017 sections 2 and 10, privacy 1, 7)."""

from __future__ import annotations

import logging
import uuid
from datetime import UTC, datetime

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.services.erasure import erase_account
from app.services.export_archive import build_archive, collect_account_data, exported_columns
from app.services.personal_data import REDIS_KEYSPACES, TABLE_CLASSIFICATION
from app.services.users import lock_user
from tests.grace_helpers import app_of, count
from tests.oauth_helpers import (
    CONSENTS,
    SUBJECT,
    bearer,
    new_nonce,
    oauth_account,
    redis_keys,
    sign_in,
    sign_up,
    ticket_of,
)
from tests.test_export_archive import read

NOW = datetime(2026, 11, 10, 12, 0, tzinfo=UTC)
EMAIL = "oauth-user@example.com"


def test_identities_are_personal_data_with_an_export_decision() -> None:
    info = TABLE_CLASSIFICATION["auth_identities"]
    assert (info.kind, info.owner_column, info.owner_ref) == ("personal", "user_id", "user")
    assert info.export == "rows"
    assert info.export_exclude == ("provider_refresh_token_enc",)


def test_the_export_carries_the_subject_and_never_the_encrypted_token() -> None:
    columns = exported_columns("auth_identities")
    assert "subject" in columns
    assert "provider_refresh_token_enc" not in columns
    assert {"id", "user_id", "provider", "email_at_link", "created_at", "last_used_at"} <= set(
        columns
    )


def test_the_new_redis_keyspaces_are_declared() -> None:
    assert {"ot:", "oc:", "on:"} <= set(REDIS_KEYSPACES)
    assert REDIS_KEYSPACES["ot:"].kind == "personal"  # a sign-up ticket holds a provider subject


@pytest.mark.usefixtures("oauth_on")
async def test_every_redis_key_of_the_flows_is_declared_and_hashed(client: AsyncClient) -> None:
    nonce = await new_nonce(client)
    resp = await sign_in(client, email=EMAIL, nonce=nonce, jti="visible-jti")
    ticket = ticket_of(resp)
    assert (await sign_up(client, ticket, consents=CONSENTS)).status_code == 201
    other = ticket_of(await sign_in(client, sub="another", email=None, verified=False))
    await sign_up(client, other, email="typed@example.com")  # leaves a pending identity
    keys = await redis_keys()
    assert any(k.startswith("on:") for k in keys)
    assert any(k.startswith("ot:") for k in keys)
    undeclared = [k for k in keys if not k.startswith(tuple(REDIS_KEYSPACES))]
    assert not undeclared
    for secret in (nonce, ticket, other, "visible-jti", SUBJECT, EMAIL, "typed@example.com"):
        assert not any(secret in key for key in keys)


@pytest.mark.usefixtures("oauth_on")
async def test_the_export_holds_the_identity_with_its_subject(client: AsyncClient) -> None:
    tokens = await oauth_account(client)
    user_id = (await client.get("/v1/me", headers=bearer(tokens))).json()["id"]
    async with app_of(client).state.sessionmaker() as session:
        data = await collect_account_data(session, uuid.UUID(user_id))
    members = read(build_archive(data, region="ru", now=NOW))
    rows = members["tables/auth_identities.json"]
    assert len(rows) == 1
    assert rows[0]["subject"] == SUBJECT
    assert rows[0]["provider"] == "vk_id"
    assert rows[0]["user_id"] == user_id
    assert "provider_refresh_token_enc" not in rows[0]
    users = members["tables/users.json"]
    assert "password_hash" not in users[0]


@pytest.mark.usefixtures("oauth_on")
async def test_an_account_export_never_holds_another_accounts_identity(
    client: AsyncClient,
) -> None:
    first = await oauth_account(client, sub="first", email="first@example.com")
    await oauth_account(client, sub="second", email="second@example.com")
    user_id = (await client.get("/v1/me", headers=bearer(first))).json()["id"]
    async with app_of(client).state.sessionmaker() as session:
        data = await collect_account_data(session, uuid.UUID(user_id))
    rows = read(build_archive(data, region="ru", now=NOW))["tables/auth_identities.json"]
    assert [r["subject"] for r in rows] == ["first"]


@pytest.mark.usefixtures("oauth_on")
async def test_erasing_an_account_erases_its_identities(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    keep = await oauth_account(client, sub="kept", email="kept@example.com")
    gone = await oauth_account(client, sub="erased", email="erased@example.com")
    user_id = uuid.UUID((await client.get("/v1/me", headers=bearer(gone))).json()["id"])
    async with app_of(client).state.sessionmaker() as session:
        assert await lock_user(session, user_id) is not None
        await erase_account(session, user_id, now=NOW, managed_archive_retention_days=365)
        await session.commit()
    assert await count(engine, "auth_identities", "user_id = :u", u=user_id) == 0
    assert await count(engine, "auth_identities") == 1
    assert (await client.get("/v1/me", headers=bearer(keep))).status_code == 200
    # The provider identity is free again: signing in starts a new sign-up.
    assert ticket_of(await sign_in(client, sub="erased", email="erased@example.com"))


@pytest.mark.usefixtures("oauth_on")
async def test_deleting_the_user_row_cascades_to_identities(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    tokens = await oauth_account(client)
    user_id = (await client.get("/v1/me", headers=bearer(tokens))).json()["id"]
    async with engine.begin() as conn:
        await conn.execute(text("DELETE FROM users WHERE id = CAST(:u AS uuid)"), {"u": user_id})
    assert await count(engine, "auth_identities") == 0


@pytest.mark.usefixtures("oauth_on")
async def test_no_secret_reaches_the_logs(
    client: AsyncClient,
    caplog: pytest.LogCaptureFixture,
    capsys: pytest.CaptureFixture[str],
) -> None:
    caplog.set_level(logging.DEBUG)
    nonce = await new_nonce(client)
    ticket = ticket_of(await sign_in(client, sub="log-subject", email=EMAIL, nonce=nonce))
    assert (await sign_up(client, ticket, consents=CONSENTS)).status_code == 201
    bad = await sign_in(client, sub="log-subject", nonce=nonce, jti="log-jti")  # replayed nonce
    assert bad.status_code == 401
    fallback = ticket_of(await sign_in(client, sub="log-two", email=None, verified=False))
    await sign_up(client, fallback, email="log-typed@example.com")
    captured = capsys.readouterr()
    seen = captured.out + captured.err + caplog.text
    for secret in (
        nonce,
        ticket,
        fallback,
        "log-subject",
        "log-two",
        "log-jti",
        EMAIL,
        "log-typed",
    ):
        assert secret not in seen, "a secret reached the logs"
