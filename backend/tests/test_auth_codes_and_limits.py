"""Email verification, password reset and auth rate limiting."""

from __future__ import annotations

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.email import InMemoryEmailSender
from app.main import create_app
from tests.conftest import make_settings
from tests.helpers import last_code, register, register_unverified


async def test_verify_email_with_code(client: AsyncClient) -> None:
    email = await register_unverified(client)
    code = last_code(client, email)
    resp = await client.post("/v1/auth/verify-email", json={"email": email, "code": code})
    assert resp.status_code == 200
    headers = {"Authorization": f"Bearer {resp.json()['access_token']}"}
    assert (await client.get("/v1/me", headers=headers)).json()["email_verified"] is True
    # Code is single use.
    again = await client.post("/v1/auth/verify-email", json={"email": email, "code": code})
    assert again.status_code == 400


async def test_verify_email_failures_are_indistinguishable(client: AsyncClient) -> None:
    email = await register_unverified(client)
    code = last_code(client, email)
    wrong = "000000" if code != "000000" else "111111"
    bad = await client.post("/v1/auth/verify-email", json={"email": email, "code": wrong})
    unknown = await client.post(
        "/v1/auth/verify-email", json={"email": "ghost@example.com", "code": code}
    )
    assert bad.status_code == unknown.status_code == 400
    assert bad.json() == unknown.json()
    assert bad.json()["error"]["code"] == "invalid_code"


async def test_verification_codes_are_stored_hashed(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    email = await register_unverified(client)
    code = last_code(client, email)
    async with engine.connect() as conn:
        hashes = (await conn.execute(text("SELECT code_hash FROM email_codes"))).scalars().all()
    assert hashes
    assert all(code not in h for h in hashes)


async def test_wrong_code_attempts_are_limited(client: AsyncClient) -> None:
    email = await register_unverified(client)
    code = last_code(client, email)
    wrong = "000000" if code != "000000" else "111111"
    for _ in range(5):
        resp = await client.post("/v1/auth/verify-email", json={"email": email, "code": wrong})
        assert resp.status_code == 400
        assert resp.json()["error"]["code"] == "invalid_code"
    # After max attempts even the right code is refused.
    resp = await client.post("/v1/auth/verify-email", json={"email": email, "code": code})
    assert resp.status_code == 400


async def test_expired_code_is_rejected(client: AsyncClient, engine: AsyncEngine) -> None:
    email = await register_unverified(client)
    code = last_code(client, email)
    async with engine.begin() as conn:
        await conn.execute(text("UPDATE email_codes SET expires_at = now() - interval '1s'"))
    resp = await client.post("/v1/auth/verify-email", json={"email": email, "code": code})
    assert resp.status_code == 400


async def test_resend_verification_invalidates_previous_code(
    client: AsyncClient, email_sender: InMemoryEmailSender
) -> None:
    email = await register_unverified(client)
    old = last_code(client, email)
    resp = await client.post("/v1/auth/verify-email/resend", json={"email": email})
    assert resp.status_code == 202
    new = last_code(client, email)
    if old != new:
        bad = await client.post("/v1/auth/verify-email", json={"email": email, "code": old})
        assert bad.status_code == 400
    ok = await client.post("/v1/auth/verify-email", json={"email": email, "code": new})
    assert ok.status_code == 200
    # Already verified or unknown: resend answers the same and sends nothing.
    count = len(email_sender.outbox)
    for target in (email, "nobody@example.com"):
        resp = await client.post("/v1/auth/verify-email/resend", json={"email": target})
        assert resp.status_code == 202
        assert resp.json() == {"status": "accepted"}
    assert len(email_sender.outbox) == count


async def test_verify_code_format_validated(client: AsyncClient) -> None:
    email = await register_unverified(client)
    resp = await client.post("/v1/auth/verify-email", json={"email": email, "code": "12ab56"})
    assert resp.status_code == 422


async def test_password_reset_flow(client: AsyncClient, email_sender: InMemoryEmailSender) -> None:
    user = await register(client)
    other_session = (
        await client.post("/v1/auth/login", json={"email": user.email, "password": user.password})
    ).json()["refresh_token"]

    resp = await client.post("/v1/auth/password-reset/request", json={"email": user.email})
    assert resp.status_code == 202
    msg = email_sender.outbox[-1]
    assert msg.purpose == "password_reset"

    new_password = "brand new password"
    resp = await client.post(
        "/v1/auth/password-reset/confirm",
        json={"email": user.email, "code": msg.code, "new_password": new_password},
    )
    assert resp.status_code == 204

    old_login = await client.post(
        "/v1/auth/login", json={"email": user.email, "password": user.password}
    )
    assert old_login.status_code == 401
    new_login = await client.post(
        "/v1/auth/login", json={"email": user.email, "password": new_password}
    )
    assert new_login.status_code == 200
    # All existing sessions are revoked after a reset.
    assert (
        await client.post("/v1/auth/refresh", json={"refresh_token": other_session})
    ).status_code == 401


async def test_password_reset_request_does_not_reveal_email_existence(
    client: AsyncClient, email_sender: InMemoryEmailSender
) -> None:
    user = await register(client)
    sent_before = len(email_sender.outbox)
    known = await client.post("/v1/auth/password-reset/request", json={"email": user.email})
    unknown = await client.post(
        "/v1/auth/password-reset/request", json={"email": "nobody@example.com"}
    )
    assert known.status_code == unknown.status_code == 202
    assert known.json() == unknown.json()
    assert len(email_sender.outbox) == sent_before + 1


async def test_password_reset_confirm_with_bad_code_or_unknown_email(
    client: AsyncClient, email_sender: InMemoryEmailSender
) -> None:
    user = await register(client)
    await client.post("/v1/auth/password-reset/request", json={"email": user.email})
    code = email_sender.outbox[-1].code
    wrong = "000000" if code != "000000" else "111111"
    bad = await client.post(
        "/v1/auth/password-reset/confirm",
        json={"email": user.email, "code": wrong, "new_password": "whatever-123"},
    )
    unknown = await client.post(
        "/v1/auth/password-reset/confirm",
        json={"email": "ghost@example.com", "code": code, "new_password": "whatever-123"},
    )
    assert bad.status_code == unknown.status_code == 400
    assert bad.json() == unknown.json()
    # Verification code cannot be used for a reset (purpose separation).
    verify_code = next(m.code for m in email_sender.outbox if m.purpose == "verify_email")
    cross = await client.post(
        "/v1/auth/password-reset/confirm",
        json={"email": user.email, "code": verify_code, "new_password": "whatever-123"},
    )
    if verify_code != code:
        assert cross.status_code == 400


async def test_password_reset_confirm_validates_new_password(client: AsyncClient) -> None:
    resp = await client.post(
        "/v1/auth/password-reset/confirm",
        json={"email": "a@example.com", "code": "123456", "new_password": "short"},
    )
    assert resp.status_code == 422


async def test_login_is_rate_limited_per_ip_and_email(client: AsyncClient) -> None:
    user = await register(client)
    limit = 20  # tests.conftest.make_settings
    for _ in range(limit):
        resp = await client.post(
            "/v1/auth/login", json={"email": user.email, "password": "bad-password"}
        )
        assert resp.status_code == 401
    blocked = await client.post(
        "/v1/auth/login", json={"email": user.email, "password": user.password}
    )
    assert blocked.status_code == 429
    assert blocked.json()["error"]["code"] == "rate_limited"
    assert int(blocked.headers["Retry-After"]) > 0
    # A different email from the same IP is a different bucket.
    other = await client.post(
        "/v1/auth/login", json={"email": "other@example.com", "password": "bad-password"}
    )
    assert other.status_code == 401


async def test_rate_limits_apply_to_register_reset_and_verify(migrated_db: str) -> None:
    from httpx import ASGITransport

    from tests.conftest import TEST_REDIS_URL

    settings = make_settings(rate_limit_auth_max_attempts=2)
    sender = InMemoryEmailSender()
    app = create_app(settings, email_sender=sender)
    from redis.asyncio import Redis

    r: Redis = Redis.from_url(TEST_REDIS_URL)
    await r.flushdb()
    await r.aclose()
    async with (
        app.router.lifespan_context(app),
        AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c,
    ):
        for _ in range(2):
            await c.post("/v1/auth/password-reset/request", json={"email": "rl@example.com"})
        resp = await c.post("/v1/auth/password-reset/request", json={"email": "rl@example.com"})
        assert resp.status_code == 429

        body = {"email": "rl2@example.com", "password": "short", "region": "ru"}
        for _ in range(2):
            await c.post("/v1/auth/register", json=body)
        assert (await c.post("/v1/auth/register", json=body)).status_code == 429

        confirm = {"email": "rl3@example.com", "code": "123456", "new_password": "xxxxxxxx1"}
        for _ in range(2):
            await c.post("/v1/auth/password-reset/confirm", json=confirm)
        assert (await c.post("/v1/auth/password-reset/confirm", json=confirm)).status_code == 429


async def test_rate_limiter_fails_open_when_redis_is_down(migrated_db: str) -> None:
    from httpx import ASGITransport

    settings = make_settings(redis_url="redis://127.0.0.1:1/0", rate_limit_auth_max_attempts=1)
    app = create_app(settings, email_sender=InMemoryEmailSender())
    async with (
        app.router.lifespan_context(app),
        AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c,
    ):
        for _ in range(3):
            resp = await c.post(
                "/v1/auth/login", json={"email": "down@example.com", "password": "whatever1"}
            )
            assert resp.status_code == 401


def _client_from(app: object, ip: str) -> AsyncClient:
    transport = ASGITransport(app=app, client=(ip, 40000))  # type: ignore[arg-type]
    return AsyncClient(transport=transport, base_url="http://t")


@pytest.mark.parametrize(
    ("path", "body"),
    [
        ("/v1/auth/login", {"password": "bad-password"}),
        ("/v1/auth/password-reset/request", {}),
        ("/v1/auth/verify-email", {"code": "000000"}),
        ("/v1/auth/verify-email/resend", {}),
        ("/v1/auth/register", {"password": "some password", "region": "ru"}),
    ],
)
async def test_per_account_bucket_is_ip_independent(
    app_and_engine: tuple[object, object], clean_state: None, path: str, body: dict[str, str]
) -> None:
    app = app_and_engine[0]
    limit = 20  # tests.conftest.make_settings
    email = "target@example.com"
    for i in range(limit):
        async with _client_from(app, f"10.0.{i // 250}.{i % 250 + 1}") as c:
            resp = await c.post(path, json={"email": email, **body})
            assert resp.status_code != 429, (i, resp.text)
    async with _client_from(app, "192.0.2.99") as c:
        blocked = await c.post(path, json={"email": email, **body})
        assert blocked.status_code == 429
        assert blocked.json()["error"]["code"] == "rate_limited"
        # Another account from the same fresh IP is unaffected.
        other = await c.post(path, json={"email": "someone-else@example.com", **body})
        assert other.status_code != 429


async def test_password_reset_codes_are_capped_per_day(
    client: AsyncClient, email_sender: InMemoryEmailSender
) -> None:
    user = await register(client)
    for _ in range(7):
        resp = await client.post("/v1/auth/password-reset/request", json={"email": user.email})
        assert resp.status_code == 202
    resets = [m for m in email_sender.outbox if m.purpose == "password_reset"]
    assert len(resets) == 5


async def test_failed_code_attempts_accumulate_across_codes(
    client: AsyncClient, email_sender: InMemoryEmailSender
) -> None:
    user = await register(client)

    async def new_code() -> str:
        resp = await client.post("/v1/auth/password-reset/request", json={"email": user.email})
        assert resp.status_code == 202
        return last_code(client, user.email, "password_reset")

    def confirm(code: str) -> dict[str, str]:
        return {"email": user.email, "code": code, "new_password": "new password 123"}

    for _ in range(2):
        code = await new_code()
        wrong = "000000" if code != "000000" else "111111"
        for _ in range(5):
            resp = await client.post("/v1/auth/password-reset/confirm", json=confirm(wrong))
            assert resp.status_code == 400
    # A fresh code does not reset the per-account budget of failed attempts.
    code = await new_code()
    resp = await client.post("/v1/auth/password-reset/confirm", json=confirm(code))
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "invalid_code"
