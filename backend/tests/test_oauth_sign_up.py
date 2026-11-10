"""OAuth sign-up (ADR 0017 section 5): the ticket, consents, both address paths, the fallback."""

from __future__ import annotations

import json
from collections.abc import Callable
from contextlib import AbstractAsyncContextManager
from typing import Any

import pytest
from httpx import AsyncClient, Response
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from tests.grace_helpers import count, login, scalar, sent_to
from tests.helpers import DEFAULT_PASSWORD, last_code, register, register_unverified
from tests.oauth_helpers import (
    CONSENTS,
    SUBJECT,
    bearer,
    plant_ticket,
    redis_client,
    redis_keys,
    sign_in,
    sign_up,
    ticket_key,
    ticket_of,
)

EMAIL = "oauth-user@example.com"


async def verified_ticket(client: AsyncClient, email: str = EMAIL, sub: str = SUBJECT) -> str:
    return ticket_of(await sign_in(client, sub=sub, email=email, verified=True))


# --- the verified-address path ------------------------------------------------------------------


@pytest.mark.usefixtures("oauth_on")
async def test_sign_up_creates_the_account_profile_identity_consents_and_tokens(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    ticket = await verified_ticket(client, "  Mixed.Case@Example.com")
    resp = await sign_up(
        client,
        ticket,
        locale="ru",
        display_name="Аня",
        consents=CONSENTS,
        headers={"X-Device-ID": "dev-1"},
    )
    assert resp.status_code == 201, resp.text
    tokens = resp.json()
    me = (await client.get("/v1/me", headers=bearer(tokens))).json()
    assert me["email"] == "mixed.case@example.com"
    assert me["email_verified"] is True
    assert me["has_password"] is False
    assert me["locale"] == "ru"
    assert me["region"] == "ru"
    profiles = (await client.get("/v1/profiles", headers=bearer(tokens))).json()["items"]
    assert [(p["kind"], p["display_name"]) for p in profiles] == [("self", "Аня")]
    assert (
        await scalar(engine, "SELECT count(*) FROM auth_identities WHERE provider = 'vk_id'") == 1
    )
    assert await scalar(engine, "SELECT email_at_link FROM auth_identities") == me["email"]
    async with engine.connect() as conn:
        rows = (await conn.execute(text("SELECT kind, source FROM consents"))).all()
    assert sorted(tuple(row) for row in rows) == [
        ("health_data", "oauth_signup"),
        ("privacy", "oauth_signup"),
        ("terms", "oauth_signup"),
    ]
    assert await count(engine, "devices", "device_id = 'dev-1'") == 1


@pytest.mark.usefixtures("oauth_on")
async def test_the_second_sign_in_is_a_login_of_the_same_account(
    client: AsyncClient,
) -> None:
    tokens = (await sign_up(client, await verified_ticket(client), consents=CONSENTS)).json()
    again = await sign_in(client, email=EMAIL)
    assert again.status_code == 200
    ids = {
        (await client.get("/v1/me", headers=bearer(t))).json()["id"] for t in (tokens, again.json())
    }
    assert len(ids) == 1


@pytest.mark.usefixtures("oauth_on")
async def test_sign_up_without_consents_follows_the_registration_rule(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch, engine: AsyncEngine
) -> None:
    ticket = await verified_ticket(client)
    monkeypatch.setattr(settings, "consent_required_at_registration", True)
    resp = await sign_up(client, ticket)
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "consent_required"
    assert await count(engine, "users") == 0
    # The refusal did not burn the ticket.
    assert (await sign_up(client, ticket, consents=CONSENTS)).status_code == 201


@pytest.mark.usefixtures("oauth_on")
@pytest.mark.parametrize(
    ("consents", "code"),
    [
        ([{"kind": "catalog_contribution", "version": 1}], "unsupported_consent_kind"),
        (
            [
                {"kind": "health_data", "version": 9},
                {"kind": "terms", "version": 1},
                {"kind": "privacy", "version": 1},
            ],
            "unsupported_consent_version",
        ),
        (CONSENTS[:2], "consent_required"),
    ],
)
async def test_consents_are_validated_like_registration(
    client: AsyncClient, consents: list[dict[str, object]], code: str
) -> None:
    ticket = await verified_ticket(client)
    resp = await sign_up(client, ticket, consents=consents)
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == code
    assert (await sign_up(client, ticket, consents=CONSENTS)).status_code == 201


@pytest.mark.usefixtures("oauth_on")
async def test_duplicate_consent_kinds_are_a_validation_error(client: AsyncClient) -> None:
    ticket = await verified_ticket(client)
    resp = await sign_up(client, ticket, consents=[CONSENTS[0], CONSENTS[0]])
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "validation_error"


@pytest.mark.usefixtures("oauth_on")
async def test_a_ticket_is_single_use(client: AsyncClient, engine: AsyncEngine) -> None:
    ticket = await verified_ticket(client)
    assert (await sign_up(client, ticket, consents=CONSENTS)).status_code == 201
    again = await sign_up(client, ticket, consents=CONSENTS)
    assert again.status_code == 401
    assert again.json()["error"]["code"] == "invalid_provider_token"
    assert await count(engine, "users") == 1


@pytest.mark.usefixtures("oauth_on")
@pytest.mark.parametrize(
    "body",
    [
        {"region": "eu"},  # another region than this server's
        {"locale": "de"},
        {"timezone": "Mars/Base"},
        {"display_name": "x" * 500},
        {"email": "not an address"},
        {"unknown": 1},
    ],
)
async def test_an_invalid_body_is_a_422_and_does_not_burn_the_ticket(
    client: AsyncClient, body: dict[str, object]
) -> None:
    ticket = await verified_ticket(client)
    resp = await sign_up(client, ticket, **{"region": "ru", **body})  # type: ignore[arg-type]
    assert resp.status_code == 422, resp.text
    assert resp.json()["error"]["code"] == "validation_error"
    assert (await sign_up(client, ticket)).status_code == 201


@pytest.mark.usefixtures("oauth_on")
async def test_the_body_region_must_equal_the_server_region(client: AsyncClient) -> None:
    ticket = await verified_ticket(client)
    resp = await sign_up(client, ticket, region="eu")
    assert resp.status_code == 422
    assert resp.json()["error"]["details"][0]["loc"] == ["body", "region"]


@pytest.mark.usefixtures("oauth_on")
async def test_an_unknown_or_expired_ticket_is_the_same_401(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    unknown = await sign_up(client, "no-such-ticket")
    assert unknown.status_code == 401
    assert unknown.json()["error"]["code"] == "invalid_provider_token"
    ticket = await verified_ticket(client)
    async with redis_client() as redis:
        await redis.delete(ticket_key(ticket))  # what the TTL does
    expired = await sign_up(client, ticket)
    assert (expired.status_code, expired.json()) == (401, unknown.json())
    assert await count(engine, "users") == 0


@pytest.mark.usefixtures("oauth_on")
@pytest.mark.parametrize(
    "overrides",
    [
        {"region": "eu"},  # a ticket of the other region
        {"platform": "ios"},  # VK ID is not offered on iOS
        {"provider": "apple", "platform": "ios"},  # a provider RU does not have
    ],
)
async def test_a_ticket_bound_to_another_region_or_platform_is_refused(
    client: AsyncClient, settings: Settings, engine: AsyncEngine, overrides: dict[str, str]
) -> None:
    ticket = await plant_ticket(settings, **overrides)
    resp = await sign_up(client, ticket)
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_provider_token"
    assert await count(engine, "users") == 0
    assert (await sign_up(client, ticket)).status_code == 401  # and it is spent


@pytest.mark.usefixtures("oauth_on")
async def test_a_ticket_dies_when_the_provider_is_switched_off(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    ticket = await verified_ticket(client)
    monkeypatch.setattr(settings, "oauth_fake_provider", False)
    assert (await sign_up(client, ticket)).status_code == 401


async def test_eu_sign_up_with_apple(eu_client: AsyncClient, engine: AsyncEngine) -> None:
    ticket = ticket_of(
        await sign_in(
            eu_client, "apple", "apple-sub", platform="ios", email="eu@example.com", verified=True
        )
    )
    assert (await sign_up(eu_client, ticket, region="ru")).status_code == 422
    resp = await sign_up(eu_client, ticket, region="eu", consents=CONSENTS)
    assert resp.status_code == 201, resp.text
    assert await scalar(engine, "SELECT region FROM users") == "eu"
    assert await scalar(engine, "SELECT provider FROM auth_identities") == "apple"


@pytest.mark.usefixtures("oauth_on")
async def test_a_verified_address_replaces_an_unverified_password_row(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    email = await register_unverified(client, "squatter@example.com", consents=CONSENTS)
    old_id = await scalar(engine, "SELECT id FROM users WHERE email = :e", e=email)
    assert await count(engine, "consents", "user_id = :u", u=old_id) == 3
    # The unverified row does not count as an existing account at sign-in.
    ticket = await verified_ticket(client, email)
    resp = await sign_up(client, ticket, consents=CONSENTS)
    assert resp.status_code == 201, resp.text
    assert await count(engine, "users", "lower(email) = :e", e=email) == 1
    new_id = await scalar(engine, "SELECT id FROM users WHERE email = :e", e=email)
    assert new_id != old_id
    assert await count(engine, "profiles", "owner_user_id = :u", u=old_id) == 0
    assert await count(engine, "email_codes", "user_id = :u", u=old_id) == 0
    assert await count(engine, "consents", "user_id = :u", u=old_id) == 0
    assert await scalar(engine, "SELECT email_verified_at IS NOT NULL FROM users") is True
    # The squatter's password opens nothing.
    assert (await login(client, email, DEFAULT_PASSWORD)).status_code == 401


@pytest.mark.usefixtures("oauth_on")
async def test_a_verified_account_created_while_the_ticket_waited_is_a_409(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    ticket = await verified_ticket(client, "late@example.com")
    await register(client, email="late@example.com")
    resp = await sign_up(client, ticket)
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "oauth_account_exists"
    assert await count(engine, "users") == 1
    assert await count(engine, "auth_identities") == 0


@pytest.mark.usefixtures("oauth_on")
async def test_the_same_identity_cannot_sign_up_twice_through_two_tickets(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    first = await verified_ticket(client, "one@example.com")
    second = await verified_ticket(client, "two@example.com")  # same subject, still unknown
    assert (await sign_up(client, first)).status_code == 201
    resp = await sign_up(client, second)
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "oauth_account_exists"
    assert await count(engine, "users") == 1
    assert await count(engine, "auth_identities") == 1


@pytest.mark.usefixtures("oauth_on")
async def test_an_oauth_account_has_no_password_to_log_in_or_delete_with(
    client: AsyncClient,
) -> None:
    tokens = (await sign_up(client, await verified_ticket(client))).json()
    for password in ("", "anything at all", DEFAULT_PASSWORD):
        resp = await login(client, EMAIL, password)
        assert resp.status_code == 401
        assert resp.json()["error"]["code"] == "invalid_credentials"
    deleted = await client.request(
        "DELETE", "/v1/me", json={"password": "anything at all"}, headers=bearer(tokens)
    )
    assert deleted.status_code == 401
    assert deleted.json()["error"]["code"] == "invalid_password"


@pytest.mark.usefixtures("oauth_on")
async def test_a_password_reset_gives_the_account_a_real_password(client: AsyncClient) -> None:
    tokens = (await sign_up(client, await verified_ticket(client))).json()
    assert (
        await client.post("/v1/auth/password-reset/request", json={"email": EMAIL})
    ).status_code == 202
    resp = await client.post(
        "/v1/auth/password-reset/confirm",
        json={
            "email": EMAIL,
            "code": last_code(client, EMAIL, "password_reset"),
            "new_password": "a brand new password",
        },
    )
    assert resp.status_code == 204
    logged = await login(client, EMAIL, "a brand new password")
    assert logged.status_code == 200
    me = await client.get("/v1/me", headers=bearer(logged.json()))
    assert me.json()["has_password"] is True
    assert tokens["access_token"] != logged.json()["access_token"]


async def test_a_password_account_reports_has_password(client: AsyncClient) -> None:
    user = await register(client)
    me = await client.get("/v1/me", headers=user.headers)
    assert me.json()["has_password"] is True


# --- the e-mail fallback (the provider verified no address) -------------------------------------

TYPED = "typed@example.com"


async def fallback_ticket(client: AsyncClient, email: str | None = "vk@example.com") -> str:
    """A ticket of a provider that did not verify the address (or gave none)."""
    resp = await sign_in(client, email=email, verified=False)
    ticket = ticket_of(resp)
    assert resp.json()["error"]["details"]["email_required"] is True
    return ticket


async def started(client: AsyncClient, email: str = TYPED, **extra: Any) -> str:
    """Start the fallback; returns the ``pending_token`` of the 202."""
    resp = await sign_up(client, await fallback_ticket(client), email=email, **extra)
    assert resp.status_code == 202, resp.text
    return str(resp.json()["pending_token"])


def verify_body(
    client: AsyncClient, token: str | None, email: str = TYPED, code: str | None = None
) -> dict[str, str]:
    body = {"email": email, "code": code or last_code(client, email)}
    if token is not None:
        body["pending_token"] = token
    return body


async def verify_fallback(client: AsyncClient, token: str | None, email: str = TYPED) -> Response:
    return await client.post("/v1/auth/verify-email", json=verify_body(client, token, email))


@pytest.mark.usefixtures("oauth_on")
@pytest.mark.parametrize("asserted", [None, "vk@example.com"])
async def test_without_a_verified_address_the_email_is_required_and_not_burned(
    client: AsyncClient, asserted: str | None
) -> None:
    ticket = await fallback_ticket(client, asserted)
    resp = await sign_up(client, ticket)
    assert resp.status_code == 422
    assert resp.json()["error"]["details"][0]["loc"] == ["body", "email"]
    assert (await sign_up(client, ticket, email=TYPED)).status_code == 202


@pytest.mark.usefixtures("oauth_on")
async def test_the_fallback_mails_a_code_and_issues_no_token(
    client: AsyncClient, engine: AsyncEngine, settings: Settings
) -> None:
    ticket = await fallback_ticket(client)
    resp = await sign_up(client, ticket, email="Typed@Example.com", consents=CONSENTS)
    assert resp.status_code == 202, resp.text
    body = resp.json()
    assert body["status"] == "verification_sent"
    assert len(body["pending_token"]) >= 22  # 128 bits or more, URL-safe
    assert "access_token" not in resp.text
    assert last_code(client, TYPED)
    assert await scalar(engine, "SELECT email_verified_at IS NULL FROM users") is True
    assert await count(engine, "auth_identities") == 0  # attached only after the code
    pending = [k for k in await redis_keys() if k.startswith("ot:")]
    assert len(pending) == 1  # the ticket is spent; the pending identity remains
    async with redis_client() as redis:
        assert 0 < await redis.ttl(pending[0]) <= settings.email_code_ttl_seconds
        stored = (await redis.get(pending[0])).decode()
    assert body["pending_token"] not in stored  # only its hash is held
    # The unverified account opens nothing yet.
    assert (await sign_in(client, email="vk@example.com", verified=False)).status_code == 409


@pytest.mark.usefixtures("oauth_on")
async def test_the_code_with_the_token_attaches_the_identity(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    token = await started(client)
    resp = await verify_fallback(client, token)
    assert resp.status_code == 200, resp.text
    me = (await client.get("/v1/me", headers=bearer(resp.json()))).json()
    assert (me["email_verified"], me["has_password"]) == (True, False)
    assert await scalar(engine, "SELECT subject FROM auth_identities") == SUBJECT
    assert not [k for k in await redis_keys() if k.startswith("ot:")]  # consumed with GETDEL
    again = await sign_in(client, email=None)
    assert again.status_code == 200, again.text
    assert (await client.get("/v1/me", headers=bearer(again.json()))).json()["id"] == me["id"]


@pytest.mark.usefixtures("oauth_on")
async def test_a_victim_who_verifies_without_the_token_links_nothing_and_is_told(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    """The pre-hijack: an attacker starts a sign-up with the victim's address and a provider
    identity of their own, the victim later enters a code mailed to them."""
    await started(client, email="victim@example.com")  # the attacker keeps the token
    resend = await client.post("/v1/auth/verify-email/resend", json={"email": "victim@example.com"})
    assert resend.status_code == 202
    # The resent code comes with the "not linked" notice.
    assert sent_to(client, "victim@example.com", "oauth_not_linked")
    sent_before = len(sent_to(client, "victim@example.com", "oauth_not_linked"))
    resp = await client.post(
        "/v1/auth/verify-email",
        json={"email": "victim@example.com", "code": last_code(client, "victim@example.com")},
    )
    assert resp.status_code == 200  # the mailbox owner has a verified account
    assert await count(engine, "auth_identities") == 0
    assert len(sent_to(client, "victim@example.com", "oauth_not_linked")) == sent_before + 1
    assert not [k for k in await redis_keys() if k.startswith("ot:")]  # the entry is dropped
    # The attacker's provider sign-in afterwards opens nothing.
    attack = await sign_in(client, email=None, verified=False)
    assert attack.status_code == 409
    assert attack.json()["error"]["code"] == "oauth_signup_required"
    assert "access_token" not in attack.text


@pytest.mark.usefixtures("oauth_on")
@pytest.mark.parametrize("token", ["wrong-token-0123456789abcdef", ""])
async def test_a_wrong_or_missing_token_links_nothing(
    client: AsyncClient, engine: AsyncEngine, token: str
) -> None:
    await started(client)
    resp = await verify_fallback(client, token or None)
    assert resp.status_code == 200
    assert await count(engine, "auth_identities") == 0
    assert sent_to(client, TYPED, "oauth_not_linked")


@pytest.mark.usefixtures("oauth_on")
async def test_the_token_has_a_length_floor(client: AsyncClient) -> None:
    await started(client)
    resp = await client.post("/v1/auth/verify-email", json=verify_body(client, "short", TYPED))
    assert resp.status_code == 422


@pytest.mark.usefixtures("oauth_on")
async def test_a_wrong_code_does_not_spend_the_pending_identity(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    token = await started(client)
    bad = await client.post(
        "/v1/auth/verify-email", json={"email": TYPED, "code": "000000", "pending_token": token}
    )
    assert bad.status_code == 400
    assert [k for k in await redis_keys() if k.startswith("ot:")]
    assert (await verify_fallback(client, token)).status_code == 200
    assert await count(engine, "auth_identities") == 1


@pytest.mark.usefixtures("oauth_on")
async def test_the_pending_identity_is_bound_to_the_address(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    token = await started(client)
    (key,) = [k for k in await redis_keys() if k.startswith("ot:")]
    async with redis_client() as redis:
        stored = json.loads(await redis.get(key))
        assert {k: stored[k] for k in ("email", "provider", "subject")} == {
            "email": TYPED,
            "provider": "vk_id",
            "subject": SUBJECT,
        }
        stored["email"] = "someone-else@example.com"
        await redis.set(key, json.dumps(stored), ex=600)
    resp = await verify_fallback(client, token)
    assert resp.status_code == 200  # the mailbox is proven, but nothing is attached
    assert await count(engine, "auth_identities") == 0


@pytest.mark.usefixtures("oauth_on")
async def test_an_address_verified_meanwhile_attaches_nothing_and_sends_the_notice(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    token = await started(client)
    code = last_code(client, TYPED)
    # The mailbox owner verifies the address by another path (a password reset).
    await client.post("/v1/auth/password-reset/request", json={"email": TYPED})
    reset = await client.post(
        "/v1/auth/password-reset/confirm",
        json={
            "email": TYPED,
            "code": last_code(client, TYPED, "password_reset"),
            "new_password": "a brand new password",
        },
    )
    assert reset.status_code == 204
    resp = await client.post("/v1/auth/verify-email", json=verify_body(client, token, TYPED, code))
    assert resp.status_code == 200
    assert await count(engine, "auth_identities") == 0
    assert sent_to(client, TYPED, "account_exists")


@pytest.mark.usefixtures("oauth_on")
async def test_an_address_of_a_verified_account_gets_the_same_202_and_a_notice(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    await register(client, email="taken@example.com")
    before = await count(engine, "users")
    resp = await sign_up(client, await fallback_ticket(client), email="Taken@Example.com")
    assert resp.status_code == 202
    body = resp.json()
    assert body["status"] == "verification_sent"
    assert body["pending_token"]  # the same shape: no sign of the existing account
    assert sent_to(client, "taken@example.com", "account_exists")
    assert await count(engine, "users") == before
    assert await count(engine, "auth_identities") == 0
    assert not [k for k in await redis_keys() if k.startswith("ot:")]


@pytest.mark.usefixtures("oauth_on")
async def test_the_fallback_verify_fails_closed_without_redis(
    client: AsyncClient, redis_outage: Callable[[], AbstractAsyncContextManager[None]]
) -> None:
    token = await started(client)
    body = verify_body(client, token)
    async with redis_outage():
        down = await client.post("/v1/auth/verify-email", json=body)
    assert down.status_code == 503
    assert down.json()["error"]["code"] == "provider_unreachable"
    assert (await client.post("/v1/auth/verify-email", json=body)).status_code == 200  # code kept


@pytest.mark.usefixtures("oauth_on")
async def test_password_accounts_verify_without_redis(
    client: AsyncClient, redis_outage: Callable[[], AbstractAsyncContextManager[None]]
) -> None:
    email = await register_unverified(client)
    async with redis_outage():
        resp = await client.post(
            "/v1/auth/verify-email", json={"email": email, "code": last_code(client, email)}
        )
    assert resp.status_code == 200


@pytest.mark.usefixtures("oauth_on")
async def test_the_202_path_shares_the_register_budget_of_the_address(
    client: AsyncClient,
) -> None:
    for _ in range(20):
        await register_unverified(client, TYPED)
    ticket = await fallback_ticket(client)
    resp = await sign_up(client, ticket, email=TYPED)
    assert resp.status_code == 429
    assert resp.json()["error"]["code"] == "rate_limited"


@pytest.mark.usefixtures("oauth_on")
async def test_a_verified_sign_up_without_an_email_in_the_body_is_not_counted_per_address(
    client: AsyncClient,
) -> None:
    for index in range(3):
        ticket = await verified_ticket(client, f"user{index}@example.com", sub=f"sub-{index}")
        assert (await sign_up(client, ticket)).status_code == 201


@pytest.mark.usefixtures("oauth_on")
async def test_a_verified_sign_up_replaces_an_unfinished_fallback_row(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    await started(
        client, email="shared@example.com", consents=CONSENTS, headers={"X-Device-ID": "dev-old"}
    )
    old_id = await scalar(engine, "SELECT id FROM users WHERE email = 'shared@example.com'")
    assert await count(engine, "consents", "user_id = :u", u=old_id) == 3
    assert await count(engine, "devices", "user_id = :u", u=old_id) == 1
    ticket = await verified_ticket(client, "shared@example.com", sub="the-real-owner")
    assert (await sign_up(client, ticket, consents=CONSENTS)).status_code == 201
    new_id = await scalar(engine, "SELECT id FROM users WHERE email = 'shared@example.com'")
    assert new_id != old_id
    for table, column in (
        ("profiles", "owner_user_id"),
        ("consents", "user_id"),
        ("devices", "user_id"),
        ("email_codes", "user_id"),
    ):
        assert await count(engine, table, f"{column} = :u", u=old_id) == 0, table
    assert not [k for k in await redis_keys() if k.startswith("ot:")]  # its pending entry is gone
    assert await count(engine, "auth_identities") == 1
    assert await scalar(engine, "SELECT subject FROM auth_identities") == "the-real-owner"
