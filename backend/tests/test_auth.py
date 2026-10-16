"""Registration, login, refresh rotation, logout, /me."""

from __future__ import annotations

import time
import uuid
from datetime import UTC, datetime, timedelta

import jwt
import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.email import InMemoryEmailSender
from tests.grace_helpers import count, run_erase_job
from tests.helpers import DEFAULT_PASSWORD, last_code, register, register_unverified, verify


async def test_register_then_verify_returns_tokens_and_creates_self_profile(
    client: AsyncClient,
) -> None:
    resp = await client.post(
        "/v1/auth/register",
        json={
            "email": "  Alice@Example.COM ",
            "password": DEFAULT_PASSWORD,
            "region": "ru",
            "timezone": "Europe/Moscow",
            "locale": "ru",
            "display_name": "Alice",
        },
    )
    # No tokens and nothing that reveals whether the address was known.
    assert resp.status_code == 202, resp.text
    assert resp.json() == {"status": "verification_sent"}

    resp = await client.post(
        "/v1/auth/verify-email",
        json={"email": "alice@example.com", "code": last_code(client, "alice@example.com")},
    )
    assert resp.status_code == 200, resp.text
    tokens = resp.json()
    assert tokens["token_type"] == "bearer"
    assert tokens["expires_in"] == 900
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}

    me = (await client.get("/v1/me", headers=headers)).json()
    assert me["email"] == "alice@example.com"
    assert me["email_verified"] is True
    assert me["region"] == "ru"
    assert me["locale"] == "ru"
    profiles = (await client.get("/v1/profiles", headers=headers)).json()["items"]
    assert len(profiles) == 1
    assert profiles[0]["kind"] == "self"
    assert profiles[0]["timezone"] == "Europe/Moscow"
    assert profiles[0]["display_name"] == "Alice"


async def test_register_sends_verification_code(
    client: AsyncClient, email_sender: InMemoryEmailSender
) -> None:
    user = await register(client)
    assert len(email_sender.outbox) == 1
    msg = email_sender.outbox[0]
    assert msg.to == user.email
    assert msg.purpose == "verify_email"
    assert len(msg.code) == 6
    assert msg.code.isdigit()


async def test_register_wrong_region_is_409(client: AsyncClient) -> None:
    resp = await client.post(
        "/v1/auth/register",
        json={"email": "bob@example.com", "password": DEFAULT_PASSWORD, "region": "eu"},
    )
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "wrong_region"


async def test_register_existing_email_is_indistinguishable(
    client: AsyncClient, engine: AsyncEngine, email_sender: InMemoryEmailSender
) -> None:
    user = await register(client, email="dup@example.com")
    sent_before = len(email_sender.outbox)
    resp = await client.post(
        "/v1/auth/register",
        json={"email": "DUP@example.com", "password": "another password", "region": "ru"},
    )
    fresh = await client.post(
        "/v1/auth/register",
        json={"email": "fresh@example.com", "password": DEFAULT_PASSWORD, "region": "ru"},
    )
    assert resp.status_code == fresh.status_code == 202
    assert resp.json() == fresh.json()
    # The owner of the address is told that an account already exists.
    sent = email_sender.outbox[sent_before:]
    assert [(m.to, m.purpose) for m in sent] == [
        ("dup@example.com", "account_exists"),
        ("fresh@example.com", "verify_email"),
    ]
    assert sent[0].code is None
    assert sent[0].user_id == uuid.UUID(user.id)
    async with engine.connect() as conn:
        n = (
            await conn.execute(
                text("SELECT count(*) FROM users WHERE lower(email) = 'dup@example.com'")
            )
        ).scalar_one()
    assert n == 1
    # The existing password is untouched.
    ok = await client.post("/v1/auth/login", json={"email": user.email, "password": user.password})
    assert ok.status_code == 200


@pytest.mark.parametrize("password", ["short7!", "x" * 129])
async def test_register_password_length_bounds(client: AsyncClient, password: str) -> None:
    resp = await client.post(
        "/v1/auth/register",
        json={"email": "p@example.com", "password": password, "region": "ru"},
    )
    assert resp.status_code == 422


async def test_register_rejects_invalid_timezone_and_extra_fields(client: AsyncClient) -> None:
    resp = await client.post(
        "/v1/auth/register",
        json={
            "email": "tz@example.com",
            "password": DEFAULT_PASSWORD,
            "region": "ru",
            "timezone": "Mars/Olympus",
        },
    )
    assert resp.status_code == 422
    resp = await client.post(
        "/v1/auth/register",
        json={
            "email": "tz@example.com",
            "password": DEFAULT_PASSWORD,
            "region": "ru",
            "email_verified": True,
        },
    )
    assert resp.status_code == 422


async def test_password_is_stored_as_argon2id(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    async with engine.connect() as conn:
        stored = (
            await conn.execute(
                text("SELECT password_hash FROM users WHERE id = :id"), {"id": user.id}
            )
        ).scalar_one()
    assert stored.startswith("$argon2id$")
    assert user.password not in stored


async def test_login_success_and_failure_are_indistinguishable(client: AsyncClient) -> None:
    user = await register(client)
    ok = await client.post("/v1/auth/login", json={"email": user.email, "password": user.password})
    assert ok.status_code == 200
    assert set(ok.json()) == {"access_token", "refresh_token", "token_type", "expires_in"}

    wrong_pw = await client.post(
        "/v1/auth/login", json={"email": user.email, "password": "wrong-password"}
    )
    no_user = await client.post(
        "/v1/auth/login", json={"email": "ghost@example.com", "password": "wrong-password"}
    )
    assert wrong_pw.status_code == no_user.status_code == 401
    assert wrong_pw.json() == no_user.json()
    assert wrong_pw.json()["error"]["code"] == "invalid_credentials"


async def test_login_email_is_case_insensitive(client: AsyncClient) -> None:
    user = await register(client, email="case@example.com")
    resp = await client.post(
        "/v1/auth/login", json={"email": "CASE@Example.com", "password": user.password}
    )
    assert resp.status_code == 200


async def test_unverified_user_cannot_log_in(client: AsyncClient) -> None:
    email = await register_unverified(client)
    resp = await client.post("/v1/auth/login", json={"email": email, "password": DEFAULT_PASSWORD})
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "email_not_verified"
    # Only after a correct password: a wrong one is the usual 401.
    wrong = await client.post("/v1/auth/login", json={"email": email, "password": "wrong-pass"})
    assert wrong.status_code == 401
    assert wrong.json()["error"]["code"] == "invalid_credentials"
    await verify(client, email)
    ok = await client.post("/v1/auth/login", json={"email": email, "password": DEFAULT_PASSWORD})
    assert ok.status_code == 200


async def test_protected_endpoint_requires_valid_token(client: AsyncClient) -> None:
    assert (await client.get("/v1/me")).status_code == 401
    resp = await client.get("/v1/me", headers={"Authorization": "Bearer garbage"})
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "unauthorized"
    assert resp.headers["WWW-Authenticate"] == "Bearer"
    resp = await client.get("/v1/me", headers={"Authorization": "Basic Zm9vOmJhcg=="})
    assert resp.status_code == 401


async def test_expired_or_forged_access_token_rejected(client: AsyncClient) -> None:
    user = await register(client)
    claims = jwt.decode(user.access_token, options={"verify_signature": False})
    forged = jwt.encode({**claims, "exp": int(time.time()) + 3600}, "other-key" * 5, "HS256")
    assert (
        await client.get("/v1/me", headers={"Authorization": f"Bearer {forged}"})
    ).status_code == 401

    from tests.conftest import make_settings

    secret = make_settings().jwt_secret.get_secret_value()
    expired = jwt.encode({**claims, "exp": int(time.time()) - 10}, secret, "HS256")
    assert (
        await client.get("/v1/me", headers={"Authorization": f"Bearer {expired}"})
    ).status_code == 401
    other_region = jwt.encode({**claims, "region": "eu"}, secret, "HS256")
    assert (
        await client.get("/v1/me", headers={"Authorization": f"Bearer {other_region}"})
    ).status_code == 401


async def test_refresh_rotates_token(client: AsyncClient) -> None:
    user = await register(client)
    resp = await client.post("/v1/auth/refresh", json={"refresh_token": user.refresh_token})
    assert resp.status_code == 200
    new = resp.json()
    assert new["refresh_token"] != user.refresh_token
    assert (
        await client.get("/v1/me", headers={"Authorization": f"Bearer {new['access_token']}"})
    ).status_code == 200


async def test_refresh_token_reuse_revokes_family(client: AsyncClient) -> None:
    user = await register(client)
    first = await client.post("/v1/auth/refresh", json={"refresh_token": user.refresh_token})
    rotated = first.json()["refresh_token"]

    # Replay of the already-used token: treated as theft, whole family dies.
    replay = await client.post("/v1/auth/refresh", json={"refresh_token": user.refresh_token})
    assert replay.status_code == 401
    assert replay.json()["error"]["code"] == "token_reused"

    after = await client.post("/v1/auth/refresh", json={"refresh_token": rotated})
    assert after.status_code == 401


async def test_reuse_in_one_family_does_not_affect_other_sessions(client: AsyncClient) -> None:
    user = await register(client)
    login = await client.post(
        "/v1/auth/login", json={"email": user.email, "password": user.password}
    )
    other_session = login.json()["refresh_token"]
    await client.post("/v1/auth/refresh", json={"refresh_token": user.refresh_token})
    await client.post("/v1/auth/refresh", json={"refresh_token": user.refresh_token})
    resp = await client.post("/v1/auth/refresh", json={"refresh_token": other_session})
    assert resp.status_code == 200


async def test_refresh_unknown_token(client: AsyncClient) -> None:
    resp = await client.post("/v1/auth/refresh", json={"refresh_token": "x" * 43})
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_token"


async def test_refresh_expired_token(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    async with engine.begin() as conn:
        await conn.execute(text("UPDATE refresh_tokens SET expires_at = now() - interval '1s'"))
    resp = await client.post("/v1/auth/refresh", json={"refresh_token": user.refresh_token})
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_token"


async def test_logout_revokes_refresh_family(client: AsyncClient) -> None:
    user = await register(client)
    rotated = (
        await client.post("/v1/auth/refresh", json={"refresh_token": user.refresh_token})
    ).json()["refresh_token"]
    resp = await client.post("/v1/auth/logout", json={"refresh_token": rotated})
    assert resp.status_code == 204
    assert (
        await client.post("/v1/auth/refresh", json={"refresh_token": rotated})
    ).status_code == 401
    # Logout is idempotent and does not reveal token validity.
    assert (
        await client.post("/v1/auth/logout", json={"refresh_token": "nonsense"})
    ).status_code == 204


async def test_me_returns_profile_without_secrets(client: AsyncClient) -> None:
    user = await register(client)
    me = (await client.get("/v1/me", headers=user.headers)).json()
    assert me["id"] == user.id
    assert me["email"] == user.email
    assert "password_hash" not in me
    assert set(me) == {"id", "email", "email_verified", "region", "locale", "created_at"}


async def test_delete_me_ends_every_session_then_the_job_erases(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    resp = await client.request(
        "DELETE", "/v1/me", json={"password": user.password}, headers=user.headers
    )
    assert resp.status_code == 204
    # Every session ends at once, but nothing is erased during the grace period.
    assert (await client.get("/v1/me", headers=user.headers)).status_code == 401
    assert (
        await client.post("/v1/auth/refresh", json={"refresh_token": user.refresh_token})
    ).status_code == 401
    pending = await client.post(
        "/v1/auth/login", json={"email": user.email, "password": user.password}
    )
    assert pending.status_code == 403
    assert await count(engine, "users", "id = :i", i=uuid.UUID(user.id)) == 1

    report = await run_erase_job(client, datetime.now(UTC) + timedelta(days=31))
    assert report.erased == 1
    login = await client.post(
        "/v1/auth/login", json={"email": user.email, "password": user.password}
    )
    assert login.status_code == 401
    assert await count(engine, "users", "id = :i", i=uuid.UUID(user.id)) == 0
    # The address can register again once the account is erased.
    again = await register(client, email=user.email)
    assert again.id != user.id


async def test_login_records_device(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    device = f"dev-{uuid.uuid4().hex[:8]}"
    resp = await client.post(
        "/v1/auth/login",
        json={"email": user.email, "password": user.password},
        headers={"X-Device-ID": device},
    )
    assert resp.status_code == 200
    async with engine.connect() as conn:
        count = (
            await conn.execute(
                text("SELECT count(*) FROM devices WHERE user_id = :u AND device_id = :d"),
                {"u": user.id, "d": device},
            )
        ).scalar_one()
    assert count == 1


async def test_invalid_device_id_header_rejected(client: AsyncClient) -> None:
    user = await register(client)
    resp = await client.post(
        "/v1/auth/login",
        json={"email": user.email, "password": user.password},
        headers={"X-Device-ID": "bad device id with spaces"},
    )
    assert resp.status_code == 422
