"""``POST /v1/auth/restore``: ticket + mailed code bring a pending account back (ADR 0010 §2)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.conftest import FakeClock
from tests.grace_helpers import (
    app_of,
    count,
    delete_and_restore,
    login,
    pending_login,
    request_deletion,
    restore,
    scalar,
    sent_to,
)
from tests.helpers import create_medication, create_schedule, register


async def test_restore_with_ticket_and_code_brings_everything_back(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    medication = await create_medication(client, user)
    await create_schedule(client, user, medication["id"])
    assert (await request_deletion(client, user)).status_code == 204
    ticket, code = await pending_login(client, user)

    resp = await restore(client, ticket, code, device="phone-1")

    assert resp.status_code == 200
    tokens = resp.json()
    assert set(tokens) == {"access_token", "refresh_token", "token_type", "expires_in"}
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}
    assert (await client.get("/v1/me", headers=headers)).status_code == 200
    got = await client.get(f"/v1/medications/{medication['id']}", headers=headers)
    assert got.status_code == 200
    assert got.json()["name"] == "Aspirin"  # nothing had to be re-entered
    row = await scalar(
        engine, "SELECT to_jsonb(u) FROM users u WHERE id = :i", i=uuid.UUID(user.id)
    )
    assert row["deletion_requested_at"] is None
    assert row["erase_after"] is None
    refreshed = await client.post(
        "/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]}
    )
    assert refreshed.status_code == 200
    # An ordinary login works again.
    assert (await login(client, user.email, user.password)).status_code == 200


async def test_restore_without_the_code_is_refused(client: AsyncClient) -> None:
    user = await register(client)
    await request_deletion(client, user)
    ticket, _ = await pending_login(client, user)

    resp = await restore(client, ticket, None)

    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_token"
    assert (await login(client, user.email, user.password)).status_code == 403  # still pending


async def test_a_wrong_code_is_refused_and_does_not_spend_the_ticket(
    client: AsyncClient,
) -> None:
    user = await register(client)
    await request_deletion(client, user)
    ticket, code = await pending_login(client, user)
    wrong = "000000" if code != "000000" else "111111"

    bad = await restore(client, ticket, wrong)

    assert bad.status_code == 401
    assert bad.json()["error"]["code"] == "invalid_token"
    assert (await restore(client, ticket, code)).status_code == 200  # a typo is not fatal


async def test_guessing_the_code_is_budgeted_per_code(client: AsyncClient) -> None:
    user = await register(client)
    await request_deletion(client, user)
    ticket, code = await pending_login(client, user)
    wrong = "000000" if code != "000000" else "111111"
    for _ in range(5):  # EMAIL_CODE_MAX_ATTEMPTS
        assert (await restore(client, ticket, wrong)).status_code == 401
    assert (await restore(client, ticket, code)).status_code == 401  # the code is burnt


async def test_ticket_and_code_work_once(client: AsyncClient) -> None:
    user = await register(client)
    await request_deletion(client, user)
    ticket, code = await pending_login(client, user)
    assert (await restore(client, ticket, code)).status_code == 200
    assert (await restore(client, ticket, code)).status_code == 401


async def test_an_expired_or_unknown_ticket_is_refused(client: AsyncClient) -> None:
    user = await register(client)
    await request_deletion(client, user)
    ticket, code = await pending_login(client, user)
    redis = app_of(client).state.redis
    async for key in redis.scan_iter("rt:*"):
        await redis.delete(key)  # what the TTL does after 600 s

    assert (await restore(client, ticket, code)).status_code == 401
    assert (await restore(client, "not-a-ticket", code)).status_code == 401


async def test_a_ticket_needs_the_code_of_its_own_account(client: AsyncClient) -> None:
    first, second = await register(client), await register(client)
    for user in (first, second):
        await request_deletion(client, user)
    ticket_first, _ = await pending_login(client, first)
    _, code_second = await pending_login(client, second)
    assert (await restore(client, ticket_first, code_second)).status_code == 401


async def test_restore_is_refused_after_erase_after(client: AsyncClient, clock: FakeClock) -> None:
    user = await register(client)
    await request_deletion(client, user)
    ticket, code = await pending_login(client, user)
    clock.advance(days=31)
    assert (await restore(client, ticket, code)).status_code == 401


async def test_restore_mails_the_confirmation_and_rejects_older_access_tokens(
    client: AsyncClient,
) -> None:
    user = await register(client)
    tokens = app_of(client).state.tokens
    before_deletion = tokens.issue_access(
        uuid.UUID(user.id), now=datetime.now(UTC) - timedelta(seconds=30)
    )
    restored = await delete_and_restore(client, user)

    assert len(sent_to(client, user.email, "account_restored")) == 1
    old = {"Authorization": f"Bearer {before_deletion}"}
    assert (await client.get("/v1/me", headers=old)).status_code == 401  # tokens_not_before
    assert (await client.get("/v1/me", headers=restored.headers)).status_code == 200
    # The pre-deletion refresh token stays revoked.
    resp = await client.post("/v1/auth/refresh", json={"refresh_token": user.refresh_token})
    assert resp.status_code == 401


async def test_a_restored_account_can_request_deletion_again(client: AsyncClient) -> None:
    user = await register(client)
    restored = await delete_and_restore(client, user)
    assert (await request_deletion(client, restored)).status_code == 204
    ticket, code = await pending_login(client, user)
    assert (await restore(client, ticket, code)).status_code == 200


async def test_the_code_cap_still_gives_a_ticket(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    await request_deletion(client, user)
    for _ in range(5):  # EMAIL_CODE_DAILY_CAP
        await pending_login(client, user)
    assert len(sent_to(client, user.email, "restore_account")) == 5
    resp = await login(client, user.email, user.password)
    assert resp.status_code == 403
    assert resp.json()["error"]["details"]["restore_ticket"]
    assert len(sent_to(client, user.email, "restore_account")) == 5  # no sixth code
    assert await count(engine, "email_codes", "purpose = 'restore_account'") == 5


async def test_restore_is_rate_limited_and_validates_the_body(client: AsyncClient) -> None:
    assert (await client.post("/v1/auth/restore", json={})).status_code == 422
    assert (
        await client.post("/v1/auth/restore", json={"restore_ticket": "t", "extra": 1})
    ).status_code == 422
    for _ in range(200):  # the per-IP bucket: 20 attempts x 10 (tests.conftest.make_settings)
        await restore(client, "nope", "123456")
    assert (await restore(client, "nope", "123456")).status_code == 429


async def test_a_ticket_of_an_earlier_deletion_cycle_is_dead_after_a_new_request(
    client: AsyncClient,
) -> None:
    user = await register(client)
    assert (await request_deletion(client, user)).status_code == 204
    old_ticket, _ = await pending_login(client, user)
    new_ticket, code = await pending_login(client, user)
    assert (await restore(client, new_ticket, code)).status_code == 200  # cycle 1 ends

    assert (await request_deletion(client, user)).status_code == 204  # cycle 2
    fresh_ticket, fresh_code = await pending_login(client, user)

    assert (await restore(client, old_ticket, fresh_code)).status_code == 401
    # the refusal spent neither the code nor the live ticket
    assert (await restore(client, fresh_ticket, fresh_code)).status_code == 200
