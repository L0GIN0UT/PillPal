"""``POST /v1/auth/password-change/{request,confirm}``: the e-mail code is bound to the asking
session (refresh family), the others are signed out, the asking one stays."""

from __future__ import annotations

import asyncio
import logging
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from httpx import AsyncClient, Response
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from app.email import InMemoryEmailSender
from tests.export_helpers import export_row, request_export
from tests.grace_helpers import app_of, count, login, scalar, sent_to
from tests.helpers import User, last_code, register
from tests.identity_helpers import limiter_down
from tests.oauth_helpers import bearer, oauth_account
from tests.push_helpers import put_token, token_rows

REQUEST = "/v1/auth/password-change/request"
CONFIRM = "/v1/auth/password-change/confirm"
NEW = "a brand new password"
PURPOSE = "password_change"
CODES_SQL = "purpose = 'password_change'"


async def ask(client: AsyncClient, user: User, password: str | None = None) -> Response:
    body = {"current_password": user.password if password is None else password}
    return await client.post(REQUEST, json=body, headers=user.headers)


async def confirm(client: AsyncClient, user: User, code: str, new_password: str = NEW) -> Response:
    body = {"code": code, "new_password": new_password}
    return await client.post(CONFIRM, json=body, headers=user.headers)


def code_of(client: AsyncClient, user: User) -> str:
    return last_code(client, user.email, PURPOSE)


def wrong_code(code: str) -> str:
    return "000000" if code != "000000" else "111111"


def with_pair(user: User, pair: dict[str, str]) -> User:
    return User(
        user.id,
        user.email,
        user.password,
        pair["access_token"],
        pair["refresh_token"],
        user.self_profile_id,
    )


async def session_on(client: AsyncClient, user: User, device: str) -> User:
    """A new login of the account on ``device``: its own refresh family and ``sid``."""
    resp = await login(client, user.email, user.password, device=device)
    assert resp.status_code == 200, resp.text
    return with_pair(user, resp.json())


async def refresh(client: AsyncClient, user: User) -> Response:
    return await client.post("/v1/auth/refresh", json={"refresh_token": user.refresh_token})


async def password_works(client: AsyncClient, user: User, password: str) -> bool:
    resp = await login(client, user.email, password)
    return bool(resp.status_code == 200)


# --- happy path -----------------------------------------------------------------------------


async def test_change_password_end_to_end(
    client: AsyncClient, email_sender: InMemoryEmailSender
) -> None:
    user = await register(client)
    resp = await ask(client, user)
    assert resp.status_code == 202
    assert resp.json() == {"status": "accepted"}
    mail = email_sender.outbox[-1]
    assert (mail.purpose, mail.to) == (PURPOSE, user.email)

    assert (await confirm(client, user, code_of(client, user))).status_code == 204

    assert await password_works(client, user, NEW)
    assert not await password_works(client, user, user.password)
    assert len(sent_to(client, user.email, "password_changed")) == 1


async def test_the_code_is_stored_hashed(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    await ask(client, user)
    code = code_of(client, user)
    hashes = await scalar(
        engine,
        "SELECT string_agg(code_hash, ',') FROM email_codes WHERE purpose = 'password_change'",
    )
    assert hashes
    assert code not in hashes


async def test_the_code_is_single_use(client: AsyncClient) -> None:
    user = await register(client)
    await ask(client, user)
    code = code_of(client, user)
    assert (await confirm(client, user, code)).status_code == 204
    again = await confirm(client, user, code, "yet another password")
    assert again.status_code in (400, 401)
    assert await password_works(client, user, NEW)


async def test_a_new_request_invalidates_the_previous_code(client: AsyncClient) -> None:
    user = await register(client)
    await ask(client, user)
    first = code_of(client, user)
    await ask(client, user)
    second = code_of(client, user)
    if first != second:  # one in a million: the same six digits twice
        assert (await confirm(client, user, first)).status_code == 400
    assert (await confirm(client, user, second)).status_code == 204


async def test_a_password_reset_code_does_not_confirm_a_change(client: AsyncClient) -> None:
    user = await register(client)
    await client.post("/v1/auth/password-reset/request", json={"email": user.email})
    reset_code = last_code(client, user.email, "password_reset")
    await ask(client, user)
    if reset_code == code_of(client, user):
        pytest.skip("the two random codes collided")
    resp = await confirm(client, user, reset_code)
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "invalid_code"


async def test_a_reset_sends_the_password_changed_notice(client: AsyncClient) -> None:
    user = await register(client)
    await client.post("/v1/auth/password-reset/request", json={"email": user.email})
    resp = await client.post(
        "/v1/auth/password-reset/confirm",
        json={
            "email": user.email,
            "code": last_code(client, user.email, "password_reset"),
            "new_password": NEW,
        },
    )
    assert resp.status_code == 204
    assert len(sent_to(client, user.email, "password_changed")) == 1


# --- request: refusals ----------------------------------------------------------------------


async def test_request_with_a_wrong_password_is_401_and_sends_nothing(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    resp = await ask(client, user, "not the password")
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_password"
    assert await count(engine, "email_codes", CODES_SQL) == 0


@pytest.mark.usefixtures("oauth_on")
async def test_a_provider_only_account_cannot_request_with_any_password(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    headers = bearer(await oauth_account(client))
    body = {"current_password": "!oauth-no-password"}
    resp = await client.post(REQUEST, json=body, headers=headers)
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_password"
    assert await count(engine, "email_codes", CODES_SQL) == 0


async def test_requests_need_authentication(client: AsyncClient) -> None:
    assert (await client.post(REQUEST, json={"current_password": "x"})).status_code == 401
    body = {"code": "123456", "new_password": NEW}
    assert (await client.post(CONFIRM, json=body)).status_code == 401


async def test_a_token_without_a_session_is_invalid_token(client: AsyncClient) -> None:
    user = await register(client)
    legacy = app_of(client).state.tokens.issue_access(uuid.UUID(user.id))  # no ``sid``
    headers = {"Authorization": f"Bearer {legacy}"}
    for path, body in (
        (REQUEST, {"current_password": user.password}),
        (CONFIRM, {"code": "123456", "new_password": NEW}),
    ):
        resp = await client.post(path, json=body, headers=headers)
        assert resp.status_code == 401
        assert resp.json()["error"]["code"] == "invalid_token"


async def test_request_of_a_signed_out_session_spends_nothing(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    out = await client.post("/v1/auth/logout", json={"refresh_token": user.refresh_token})
    assert out.status_code == 204
    resp = await ask(client, user)  # the access token has not expired yet
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_token"
    assert await count(engine, "email_codes", CODES_SQL) == 0


@pytest.mark.parametrize(
    "body",
    [
        {},
        {"current_password": "x", "extra": 1},
        {"current_password": "x" * 129},
        {"current_password": 1},
    ],
)
async def test_request_validation(client: AsyncClient, body: dict[str, object]) -> None:
    user = await register(client)
    resp = await client.post(REQUEST, json=body, headers=user.headers)
    assert resp.status_code == 422


@pytest.mark.parametrize(
    "body",
    [
        {"code": "12345", "new_password": NEW},
        {"code": "abcdef", "new_password": NEW},
        {"code": "123456", "new_password": "short"},
        {"code": "123456", "new_password": "x" * 129},
        {"code": "123456", "new_password": NEW, "extra": 1},
        {"new_password": NEW},
    ],
)
async def test_confirm_validation(client: AsyncClient, body: dict[str, object]) -> None:
    user = await register(client)
    resp = await client.post(CONFIRM, json=body, headers=user.headers)
    assert resp.status_code == 422


async def test_the_cap_still_answers_202_and_mails_no_more(
    client: AsyncClient, email_sender: InMemoryEmailSender
) -> None:
    user = await register(client)
    for _ in range(7):
        resp = await ask(client, user)
        assert resp.status_code == 202
        assert resp.json() == {"status": "accepted"}
    assert len([m for m in email_sender.outbox if m.purpose == PURPOSE]) == 5


async def test_request_fails_closed_when_the_limiter_is_down(
    client: AsyncClient, engine: AsyncEngine, settings: Settings
) -> None:
    user = await register(client)
    async with limiter_down(client, settings):
        resp = await ask(client, user)
    assert resp.status_code == 503
    assert resp.json()["error"]["code"] == "rate_limit_unavailable"
    assert await count(engine, "email_codes", CODES_SQL) == 0


async def test_request_shares_the_login_bucket_of_the_account(client: AsyncClient) -> None:
    user = await register(client)
    limit = 20  # tests.conftest.make_settings
    for _ in range(limit // 2):
        assert (await ask(client, user, "wrong password")).status_code == 401
    for _ in range(limit // 2):
        bad = await login(client, user.email, "wrong password")
        assert bad.status_code == 401
    blocked = await ask(client, user, "wrong password")
    assert blocked.status_code == 429
    assert int(blocked.headers["Retry-After"]) > 0
    # Guessing through the change spent the budget of the login too.
    assert (await login(client, user.email, user.password)).status_code == 429


async def test_confirm_is_rate_limited_per_user(client: AsyncClient) -> None:
    user = await register(client)
    await ask(client, user)
    wrong = wrong_code(code_of(client, user))
    statuses = [(await confirm(client, user, wrong)).status_code for _ in range(21)]
    assert statuses[-1] == 429


# --- confirm: refusals ----------------------------------------------------------------------


async def test_a_wrong_code_changes_nothing_and_the_budget_ends(client: AsyncClient) -> None:
    user = await register(client)
    await ask(client, user)
    code = code_of(client, user)
    for _ in range(5):
        resp = await confirm(client, user, wrong_code(code))
        assert resp.status_code == 400
        assert resp.json()["error"]["code"] == "invalid_code"
    assert (await confirm(client, user, code)).status_code == 400  # budget spent
    assert await password_works(client, user, user.password)


async def test_an_expired_code_is_refused(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    await ask(client, user)
    code = code_of(client, user)
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "UPDATE email_codes SET expires_at = now() - interval '1s' "
                "WHERE purpose = 'password_change'"
            )
        )
    assert (await confirm(client, user, code)).status_code == 400
    assert await password_works(client, user, user.password)


async def test_a_code_without_a_request_is_refused(client: AsyncClient) -> None:
    user = await register(client)
    resp = await confirm(client, user, "123456")
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "invalid_code"


async def test_another_sessions_code_is_refused_and_still_works_for_its_session(
    client: AsyncClient,
) -> None:
    user = await register(client)
    mine = await session_on(client, user, "phone-a")
    other = await session_on(client, user, "phone-b")
    await ask(client, other)
    code = code_of(client, user)
    stolen = await confirm(client, mine, code)
    assert stolen.status_code == 400
    assert stolen.json()["error"]["code"] == "invalid_code"
    assert await password_works(client, user, user.password)
    assert (await confirm(client, other, code)).status_code == 204


async def test_confirm_of_a_signed_out_session_spends_no_code(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    await ask(client, user)
    code = code_of(client, user)
    out = await client.post("/v1/auth/logout", json={"refresh_token": user.refresh_token})
    assert out.status_code == 204
    resp = await confirm(client, user, code)
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_token"
    assert await count(engine, "email_codes", "consumed_at IS NULL AND attempts = 0") == 1
    assert await password_works(client, user, user.password)


# --- the session model ----------------------------------------------------------------------


async def test_the_code_survives_an_access_token_refresh_of_the_same_session(
    client: AsyncClient,
) -> None:
    user = await register(client)
    await ask(client, user)
    code = code_of(client, user)
    pair = (await refresh(client, user)).json()  # same family: new access and refresh tokens
    renewed = with_pair(user, pair)
    assert (await confirm(client, renewed, code)).status_code == 204
    # The session itself is neither rotated nor revoked by the change.
    assert (await refresh(client, renewed)).status_code == 200


async def test_the_other_sessions_end_and_this_one_stays(client: AsyncClient) -> None:
    user = await register(client)
    mine = await session_on(client, user, "phone-a")
    other = await session_on(client, user, "phone-b")
    await ask(client, mine)
    assert (await confirm(client, mine, code_of(client, user))).status_code == 204

    assert (await refresh(client, other)).status_code == 401
    kept = await refresh(client, mine)
    assert kept.status_code == 200
    fresh = {"Authorization": f"Bearer {kept.json()['access_token']}"}
    assert (await client.get("/v1/me", headers=fresh)).status_code == 200


async def test_an_access_token_from_before_the_change_dies(client: AsyncClient) -> None:
    user = await register(client)
    tokens = app_of(client).state.tokens
    sid = tokens.decode_access(user.access_token).session_id
    old = tokens.issue_access(
        uuid.UUID(user.id), now=datetime.now(UTC) - timedelta(seconds=30), session_id=sid
    )
    await ask(client, user)
    assert (await confirm(client, user, code_of(client, user))).status_code == 204
    resp = await client.get("/v1/me", headers={"Authorization": f"Bearer {old}"})
    assert resp.status_code == 401


@pytest.mark.usefixtures("export_on")
async def test_exports_of_the_other_sessions_expire(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    mine = await session_on(client, user, "phone-a")
    other = await session_on(client, user, "phone-b")
    export_id = (await request_export(client, other)).json()["id"]
    await ask(client, mine)
    assert (await confirm(client, mine, code_of(client, user))).status_code == 204
    row = await export_row(engine, export_id)
    assert row.status == "expired"
    assert row.archive is None


@pytest.mark.usefixtures("export_on")
async def test_the_export_of_this_session_is_kept(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    mine = await session_on(client, user, "phone-a")
    export_id = (await request_export(client, mine)).json()["id"]
    await ask(client, mine)
    assert (await confirm(client, mine, code_of(client, user))).status_code == 204
    assert (await export_row(engine, export_id)).status == "queued"


async def test_push_tokens_of_the_other_devices_go_and_this_one_stays(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    mine = await session_on(client, user, "phone-a")
    other = await session_on(client, user, "phone-b")
    assert (await put_token(client, mine, "phone-a")).status_code == 200
    assert (await put_token(client, other, "phone-b")).status_code == 200
    await ask(client, mine)
    assert (await confirm(client, mine, code_of(client, user))).status_code == 204
    assert [r.device_id for r in await token_rows(engine, user)] == ["phone-a"]


async def test_an_old_session_on_the_same_device_does_not_cost_the_device_its_token(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    old = await session_on(client, user, "phone-a")
    current = await session_on(client, user, "phone-a")  # same device, a new family
    elsewhere = await session_on(client, user, "phone-b")
    assert (await put_token(client, current, "phone-a")).status_code == 200
    assert (await put_token(client, elsewhere, "phone-b")).status_code == 200
    await ask(client, current)
    assert (await confirm(client, current, code_of(client, user))).status_code == 204
    assert (await refresh(client, old)).status_code == 401  # revoked all the same
    assert [r.device_id for r in await token_rows(engine, user)] == ["phone-a"]


async def test_concurrent_confirms_apply_one_password(client: AsyncClient) -> None:
    user = await register(client)
    await ask(client, user)
    code = code_of(client, user)
    first, second = await asyncio.gather(
        confirm(client, user, code, "first new password"),
        confirm(client, user, code, "second new password"),
    )
    statuses = sorted([first.status_code, second.status_code])
    assert statuses[0] == 204
    assert statuses[1] in (400, 401)
    winners = [
        password
        for password in ("first new password", "second new password")
        if await password_works(client, user, password)
    ]
    assert len(winners) == 1
    assert len(sent_to(client, user.email, "password_changed")) == 1


# --- privacy --------------------------------------------------------------------------------


async def test_no_password_code_or_address_reaches_the_logs(
    client: AsyncClient,
    caplog: pytest.LogCaptureFixture,
    capsys: pytest.CaptureFixture[str],
) -> None:
    caplog.set_level(logging.DEBUG)
    user = await register(client, email="log-probe@example.com")
    await ask(client, user, "wrong log password")
    await ask(client, user)
    code = code_of(client, user)
    await confirm(client, user, wrong_code(code), "never applied password")
    await confirm(client, user, code, "log new password")
    captured = capsys.readouterr()
    seen = captured.out + captured.err + caplog.text
    for secret in (
        user.password,
        "wrong log password",
        "never applied password",
        "log new password",
        code,
        "log-probe",
    ):
        assert secret not in seen, "a secret reached the logs"
