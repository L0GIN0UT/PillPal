"""``DELETE /v1/me`` starts a grace period instead of erasing (ADR 0010 §1, §3, decision D2)."""

from __future__ import annotations

import asyncio
import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from tests.conftest import FakeClock
from tests.grace_helpers import (
    app_of,
    count,
    login,
    pending_login,
    request_deletion,
    scalar,
    sent_to,
)
from tests.helpers import (
    create_invite,
    create_medication,
    last_code,
    register,
    register_unverified,
)

GRACE = timedelta(days=30)
# erase_after is set two job intervals early (one retry pass plus a missed run)
ERASE_MARGIN = timedelta(hours=2)


async def test_delete_me_keeps_the_data_and_starts_the_grace_period(
    client: AsyncClient, engine: AsyncEngine, clock: FakeClock, settings: Settings
) -> None:
    user = await register(client)
    await create_medication(client, user)

    resp = await request_deletion(client, user)

    assert resp.status_code == 204
    row = await scalar(
        engine,
        "SELECT to_jsonb(u) FROM users u WHERE id = :i",
        i=uuid.UUID(user.id),
    )
    requested = datetime.fromisoformat(row["deletion_requested_at"])
    erase_after = datetime.fromisoformat(row["erase_after"])
    assert requested == clock.now
    # Erased no later than request + grace even though the job only runs hourly (ADR 0010 §4).
    assert erase_after == requested + GRACE - ERASE_MARGIN
    assert erase_after <= requested + timedelta(days=settings.account_deletion_grace_days)
    assert row["tokens_not_before"] is not None
    assert (
        await count(engine, "medications", "profile_id = :p", p=uuid.UUID(user.self_profile_id))
        == 1
    )


async def test_delete_me_mails_the_erase_date_once(client: AsyncClient, clock: FakeClock) -> None:
    user = await register(client)
    await request_deletion(client, user)
    mails = sent_to(client, user.email, "deletion_requested")
    assert len(mails) == 1
    assert mails[0].erase_after == clock.now + GRACE - ERASE_MARGIN
    assert mails[0].code is None


async def test_a_wrong_password_changes_nothing(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    resp = await request_deletion(client, user, "not my password")
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_password"
    assert (
        await scalar(engine, "SELECT count(*) FROM users WHERE deletion_requested_at IS NOT NULL")
        == 0
    )
    assert (await client.get("/v1/me", headers=user.headers)).status_code == 200


async def test_login_of_a_pending_account_offers_the_restore(
    client: AsyncClient, clock: FakeClock
) -> None:
    user = await register(client)
    await request_deletion(client, user)

    resp = await login(client, user.email, user.password)

    assert resp.status_code == 403
    error = resp.json()["error"]
    assert error["code"] == "account_pending_deletion"
    assert set(error["details"]) == {"restore_ticket", "erase_after"}
    assert len(error["details"]["restore_ticket"]) >= 43  # 256 bits, url-safe
    assert (
        datetime.fromisoformat(error["details"]["erase_after"]) == clock.now + GRACE - ERASE_MARGIN
    )
    mails = sent_to(client, user.email, "restore_account")
    assert len(mails) == 1
    assert mails[0].code is not None
    assert "access_token" not in resp.text


async def test_login_with_a_wrong_password_reveals_nothing_about_the_deletion(
    client: AsyncClient,
) -> None:
    user = await register(client)
    await request_deletion(client, user)
    resp = await login(client, user.email, "not my password")
    assert resp.status_code == 401
    assert resp.json() == {
        "error": {"code": "invalid_credentials", "message": "Invalid e-mail or password"}
    }
    assert sent_to(client, user.email, "restore_account") == []


async def test_login_after_erase_after_is_an_ordinary_failure(
    client: AsyncClient, clock: FakeClock
) -> None:
    user = await register(client)
    await request_deletion(client, user)
    clock.advance(days=31)
    resp = await login(client, user.email, user.password)
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_credentials"


async def test_every_session_dies_with_the_request(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    other_device = await login(client, user.email, user.password, "second-phone")
    assert other_device.status_code == 200
    second = other_device.json()
    tokens = app_of(client).state.tokens
    old_access = tokens.issue_access(
        uuid.UUID(user.id), now=datetime.now(UTC) - timedelta(seconds=30)
    )

    assert (await request_deletion(client, user)).status_code == 204

    for headers in (
        user.headers,
        {"Authorization": f"Bearer {second['access_token']}"},
        {"Authorization": f"Bearer {old_access}"},
    ):
        assert (await client.get("/v1/me", headers=headers)).status_code == 401
    for refresh in (user.refresh_token, second["refresh_token"]):
        resp = await client.post("/v1/auth/refresh", json={"refresh_token": refresh})
        assert resp.status_code == 401
        assert resp.json()["error"]["code"] == "invalid_token"
    assert (
        await count(
            engine, "refresh_tokens", "user_id = :u AND revoked_at IS NULL", u=uuid.UUID(user.id)
        )
        == 0
    )


async def test_a_second_request_does_not_succeed(client: AsyncClient) -> None:
    user = await register(client)
    assert (await request_deletion(client, user)).status_code == 204
    assert (await request_deletion(client, user)).status_code == 401


async def test_no_token_is_issued_for_a_pending_account_by_any_path(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    """verify-email (a stale verification code) must not hand out a session either."""
    user = await register(client)
    await request_deletion(client, user)
    # A verification code that is still unconsumed (issued before the deletion).
    tokens = app_of(client).state.tokens
    code = "123456"
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO email_codes (id, user_id, purpose, code_hash, expires_at) "
                "VALUES (:i, :u, 'verify_email', :h, now() + interval '10 minutes')"
            ),
            {
                "i": uuid.uuid4(),
                "u": uuid.UUID(user.id),
                "h": tokens.code_hash(uuid.UUID(user.id), "verify_email", code),
            },
        )
    resp = await client.post("/v1/auth/verify-email", json={"email": user.email, "code": code})
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "account_pending_deletion"
    assert await count(engine, "refresh_tokens", "revoked_at IS NULL") == 0


async def test_open_invites_are_revoked_at_the_request(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    await create_invite(client, user)
    await create_invite(client, user)
    await request_deletion(client, user)
    assert await count(engine, "invites", "revoked_at IS NULL AND consumed_at IS NULL") == 0
    assert await count(engine, "invites") == 2  # kept until the erase, like all data


# --- registration and password reset during the grace period --------------------------------


async def test_registering_a_pending_address_creates_no_second_account(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    await request_deletion(client, user)
    before = len(sent_to(client, user.email, "restore_account"))

    await register_unverified(client, user.email)  # same 202 and body as for any address

    assert await count(engine, "users", "lower(email) = :e", e=user.email) == 1
    notices = sent_to(client, user.email, "account_pending_deletion")
    assert len(notices) == 1
    assert notices[0].code is None  # instructions only: no ticket, no code, no link
    assert notices[0].erase_after is not None
    assert len(sent_to(client, user.email, "restore_account")) == before
    assert sent_to(client, user.email, "account_exists") == []


async def test_password_reset_works_and_login_still_offers_the_restore(
    client: AsyncClient,
) -> None:
    user = await register(client)
    await request_deletion(client, user)
    await client.post("/v1/auth/password-reset/request", json={"email": user.email})
    code = last_code(client, user.email, "password_reset")
    resp = await client.post(
        "/v1/auth/password-reset/confirm",
        json={"email": user.email, "code": code, "new_password": "a brand new password"},
    )
    assert resp.status_code == 204
    # The reset does not restore by itself; the next login offers it.
    login_resp = await login(client, user.email, "a brand new password")
    assert login_resp.status_code == 403
    assert login_resp.json()["error"]["code"] == "account_pending_deletion"


# --- races ------------------------------------------------------------------------------------


@pytest.mark.parametrize("round_", range(3))
async def test_a_login_racing_the_request_never_keeps_a_working_session(
    client: AsyncClient, round_: int
) -> None:
    user = await register(client)

    login_resp, delete_resp = await asyncio.gather(
        login(client, user.email, user.password), request_deletion(client, user)
    )

    assert delete_resp.status_code == 204
    assert login_resp.status_code in (200, 403)
    if login_resp.status_code == 200:  # the login won the row lock: its session must be revoked
        tokens: dict[str, Any] = login_resp.json()
        refresh = await client.post(
            "/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]}
        )
        assert refresh.status_code == 401
        headers = {"Authorization": f"Bearer {tokens['access_token']}"}
        assert (await client.get("/v1/me", headers=headers)).status_code == 401


async def test_two_requests_at_once_leave_one_pending_account(client: AsyncClient) -> None:
    user = await register(client)
    first, second = await asyncio.gather(
        request_deletion(client, user), request_deletion(client, user)
    )
    assert sorted([first.status_code, second.status_code]) == [204, 401]


async def test_pending_login_ticket_needs_redis_and_expires_with_it(
    client: AsyncClient,
) -> None:
    user = await register(client)
    await request_deletion(client, user)
    ticket, _ = await pending_login(client, user)
    redis = app_of(client).state.redis
    keys = [k.decode() async for k in redis.scan_iter("rt:*")]
    assert len(keys) == 1
    assert ticket not in keys[0]  # only a hash of the bearer secret is stored
    ttl = app_of(client).state.settings.account_restore_ticket_ttl_seconds
    assert 0 < await redis.ttl(keys[0]) <= ttl
