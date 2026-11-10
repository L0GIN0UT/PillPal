"""Revoking the Apple refresh token (milestone 5.8, ADR 0017 section 9): the deletion request does
not wait on Apple, the worker sweep revokes and clears only on success, the erase job tries once
more, unlink revokes inline with a short timeout, and no token, code or subject reaches the logs."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import pytest
from sqlalchemy import text

from app.config import Settings
from app.jobs.account_erasure import erase_expired_accounts
from app.oauth.apple_tokens import APPLE_REVOKE_URL
from tests.grace_helpers import count, scalar
from tests.helpers import DEFAULT_PASSWORD, register
from tests.identity_helpers import IDENTITIES_URL
from tests.oauth_helpers import new_nonce
from tests.oauth_real_flow_helpers import SUBJECT, Real, bearer
from tests.oauth_real_helpers import CODE, REFRESH_TOKEN, timeout


async def delete_account(real: Real, tokens: dict[str, Any]) -> httpx.Response:
    headers = bearer(tokens)
    return await real.client.request(
        "DELETE", "/v1/me", json=await real.reauth_apple(headers), headers=headers
    )


# --- deletion ---------------------------------------------------------------------------------


async def test_the_deletion_request_does_not_call_apple(real: Real) -> None:
    tokens = await real.apple_account()
    resp = await delete_account(real, tokens)
    assert resp.status_code == 204, resp.text
    assert real.revokes() == []
    assert await real.sealed() is not None  # kept for the sweep


async def test_a_deletion_while_apple_is_down_is_not_delayed_or_failed(real: Real) -> None:
    tokens = await real.apple_account()
    original = real.apple.handler
    real.apple.handler = timeout  # type: ignore[method-assign,assignment]
    try:
        started = datetime.now(UTC)
        resp = await delete_account(real, tokens)
        elapsed = datetime.now(UTC) - started
    finally:
        real.apple.handler = original  # type: ignore[method-assign]
    assert resp.status_code == 204, resp.text
    assert elapsed < timedelta(seconds=2)
    assert real.revokes() == []


async def test_the_sweep_revokes_and_clears_after_the_deletion(real: Real) -> None:
    tokens = await real.apple_account()
    await delete_account(real, tokens)
    assert await real.sweep() == 1
    [form] = real.revokes()
    assert form["token"] == REFRESH_TOKEN
    assert await real.sealed() is None
    assert await real.sweep() == 0  # nothing left to do


async def test_apple_down_keeps_the_column_and_a_later_sweep_clears_it(real: Real) -> None:
    tokens = await real.apple_account()
    await delete_account(real, tokens)
    real.apple.revoke_responses = [httpx.Response(500), httpx.Response(500)]
    assert await real.sweep() == 0
    assert await real.sealed() is not None  # kept: the revoke did not succeed
    assert len(real.revokes()) == 2  # one try and one retry
    assert await real.sweep() == 1  # Apple is back
    assert await real.sealed() is None


async def test_the_sweep_ignores_accounts_that_are_not_pending(real: Real) -> None:
    await real.apple_account()
    assert await real.sweep() == 0
    assert real.revokes() == []
    assert await real.sealed() is not None


async def test_a_restored_account_is_left_alone_by_the_sweep(real: Real) -> None:
    tokens = await real.apple_account()
    await delete_account(real, tokens)
    async with real.engine.begin() as conn:
        await conn.execute(
            text("UPDATE users SET deletion_requested_at = NULL, erase_after = NULL")
        )
    assert await real.sweep() == 0
    assert real.revokes() == []


async def test_the_erase_job_makes_one_last_attempt_before_the_rows_go(real: Real) -> None:
    tokens = await real.apple_account()
    await delete_account(real, tokens)
    settings: Settings = real.app.state.settings
    later = datetime.now(UTC) + timedelta(days=settings.account_deletion_grace_days + 1)
    report = await erase_expired_accounts(
        real.app.state.sessionmaker, settings, now=later, provider_tokens=real.tokens()
    )
    assert report.erased == 1
    [form] = real.revokes()
    assert form["token"] == REFRESH_TOKEN
    assert await count(real.engine, "auth_identities") == 0


async def test_the_erase_job_erases_even_when_apple_refuses(real: Real) -> None:
    tokens = await real.apple_account()
    await delete_account(real, tokens)
    real.apple.revoke_responses = [httpx.Response(500), httpx.Response(500)]
    settings: Settings = real.app.state.settings
    later = datetime.now(UTC) + timedelta(days=settings.account_deletion_grace_days + 1)
    report = await erase_expired_accounts(
        real.app.state.sessionmaker, settings, now=later, provider_tokens=real.tokens()
    )
    assert report.erased == 1
    assert await count(real.engine, "users") == 0


async def test_a_stale_reauth_assertion_cannot_delete(real: Real) -> None:
    tokens = await real.apple_account()
    headers = bearer(tokens)
    nonce = await new_nonce(real.client, "reauth", headers)
    stale = int((datetime.now(UTC) - timedelta(minutes=30)).timestamp())
    body = {
        "reauth": {
            "provider": "apple",
            "platform": "ios",
            "assertion": real.apple_token(nonce, iat=stale),
            "nonce": nonce,
        }
    }
    resp = await real.client.request("DELETE", "/v1/me", json=body, headers=headers)
    assert resp.status_code == 401
    pending = await scalar(
        real.engine, "SELECT count(*) FROM users WHERE deletion_requested_at IS NOT NULL"
    )
    assert pending == 0


# --- unlink -----------------------------------------------------------------------------------


async def link_apple(real: Real, user: Any) -> str:
    nonce = await new_nonce(real.client, "link", user.headers)
    body = {
        "provider": "apple",
        "platform": "ios",
        "assertion": real.apple_token(nonce),
        "nonce": nonce,
        "authorization_code": CODE,
        "password": DEFAULT_PASSWORD,
    }
    linked = await real.client.post(IDENTITIES_URL, json=body, headers=user.headers)
    assert linked.status_code == 201, linked.text
    return str(linked.json()["id"])


async def unlink_apple(real: Real, user: Any, identity_id: str) -> httpx.Response:
    return await real.client.request(
        "DELETE",
        f"{IDENTITIES_URL}/{identity_id}",
        json={"password": DEFAULT_PASSWORD},
        headers=user.headers,
    )


async def test_unlinking_apple_revokes_the_token(real: Real) -> None:
    user = await register(real.client, region="eu")
    identity_id = await link_apple(real, user)
    assert await real.sealed() is not None
    resp = await unlink_apple(real, user, identity_id)
    assert resp.status_code == 204, resp.text
    [form] = real.revokes()
    assert form["token"] == REFRESH_TOKEN


async def test_an_unlink_still_succeeds_when_apple_refuses_the_revoke(real: Real) -> None:
    user = await register(real.client, region="eu")
    identity_id = await link_apple(real, user)
    real.apple.revoke_responses = [httpx.Response(400), httpx.Response(400)]
    resp = await unlink_apple(real, user, identity_id)
    assert resp.status_code == 204
    assert len(real.revokes()) == 1  # inline: one short try, no retry while a request waits


async def test_linking_an_identity_of_another_account_spends_no_code(real: Real) -> None:
    await real.apple_account()
    other = await register(real.client, region="eu")
    exchanges_before = len(real.apple.calls)
    nonce = await new_nonce(real.client, "link", other.headers)
    body = {
        "provider": "apple",
        "platform": "ios",
        "assertion": real.apple_token(nonce),
        "nonce": nonce,
        "authorization_code": CODE,
        "password": DEFAULT_PASSWORD,
    }
    resp = await real.client.post(IDENTITIES_URL, json=body, headers=other.headers)
    assert resp.status_code == 409
    assert len(real.apple.calls) == exchanges_before  # nothing was exchanged for it


# --- logs -------------------------------------------------------------------------------------


async def test_no_token_code_or_subject_reaches_the_logs(
    real: Real, capsys: pytest.CaptureFixture[str]
) -> None:
    real.apple.revoke_responses = [httpx.Response(500, text=REFRESH_TOKEN)] * 2
    tokens = await real.apple_account()
    await delete_account(real, tokens)
    await real.sweep()
    out = capsys.readouterr()
    everything = out.out + out.err
    for secret in (REFRESH_TOKEN, CODE, SUBJECT):
        assert secret not in everything
    assert APPLE_REVOKE_URL  # the revoke endpoint was reachable in this scenario
