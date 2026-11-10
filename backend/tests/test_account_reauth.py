"""Re-authentication by a linked provider for deletion and export (ADR 0017 section 8, 0016 s8).

An OAuth-only account has no password: it deletes its account and exports its data with a fresh
``reauth`` assertion. The password form is covered by the deletion and export suites.
"""

from __future__ import annotations

from collections.abc import Callable
from contextlib import AbstractAsyncContextManager
from datetime import UTC, datetime
from typing import Any

import pytest
from httpx import AsyncClient, Response
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.config import Settings
from tests.export_helpers import download_export, run_builder
from tests.grace_helpers import count, restore, scalar, sent_to
from tests.helpers import User, last_code, register
from tests.identity_helpers import link, reauth_proof
from tests.oauth_helpers import SUBJECT, bearer, oauth_account, sign_in

pytestmark = pytest.mark.usefixtures("oauth_on")

EMAIL = "oauth-user@example.com"
BAD_CASES = ["stale", "wrong_purpose", "not_linked", "other_accounts_identity", "replayed"]
NOT_PENDING = "SELECT count(*) FROM users WHERE deletion_requested_at IS NULL"


async def delete_with(client: AsyncClient, headers: dict[str, str], body: Any) -> Response:
    return await client.request("DELETE", "/v1/me", json=body, headers=headers)


async def export_with(client: AsyncClient, headers: dict[str, str], body: Any) -> Response:
    return await client.post("/v1/me/export", json=body, headers=headers)


async def bad_proof(client: AsyncClient, headers: dict[str, str], case: str) -> dict[str, Any]:
    """A re-auth form that must be refused, for an account signed up with ``SUBJECT``."""
    if case == "stale":
        return await reauth_proof(client, headers, "vk_id", SUBJECT, age_seconds=301)
    if case == "wrong_purpose":
        return await reauth_proof(client, headers, "vk_id", SUBJECT, purpose="link")
    if case == "not_linked":
        return await reauth_proof(client, headers, "vk_id", "never-linked")
    if case == "other_accounts_identity":
        await oauth_account(client, "vk_id", "another-subject", email="another@example.com")
        return await reauth_proof(client, headers, "vk_id", "another-subject")
    first = await reauth_proof(client, headers, "vk_id", SUBJECT, jti="spent-jti")
    assert (await link(client, headers, "yandex_id", "extra", first)).status_code == 201
    return await reauth_proof(client, headers, "vk_id", SUBJECT, jti="spent-jti")


def as_user(tokens: dict[str, Any], user_id: str) -> User:
    return User(user_id, EMAIL, "", tokens["access_token"], tokens["refresh_token"], "")


# --- DELETE /v1/me --------------------------------------------------------------------------


async def test_a_passwordless_account_deletes_itself_with_a_provider_assertion(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    headers = bearer(await oauth_account(client))
    proof = await reauth_proof(client, headers, "vk_id", SUBJECT)
    resp = await delete_with(client, headers, proof)
    assert resp.status_code == 204, resp.text
    assert await scalar(engine, "SELECT deletion_requested_at IS NOT NULL FROM users") is True
    assert len(sent_to(client, EMAIL, "deletion_requested")) == 1


@pytest.mark.parametrize("case", BAD_CASES)
async def test_a_bad_assertion_does_not_delete(
    client: AsyncClient, engine: AsyncEngine, case: str
) -> None:
    headers = bearer(await oauth_account(client))
    proof = await bad_proof(client, headers, case)
    resp = await delete_with(client, headers, proof)
    assert resp.status_code == 401, resp.text
    assert resp.json()["error"]["code"] == "invalid_provider_token"
    assert await scalar(engine, "SELECT deletion_requested_at IS NULL FROM users LIMIT 1") is True
    assert sent_to(client, EMAIL, "deletion_requested") == []


async def test_deletion_needs_exactly_one_proof(client: AsyncClient, engine: AsyncEngine) -> None:
    headers = bearer(await oauth_account(client))
    proof = await reauth_proof(client, headers, "vk_id", SUBJECT)
    for body in (None, {}, {"password": "pw", **proof}):
        assert (await delete_with(client, headers, body)).status_code == 422
    assert await scalar(engine, NOT_PENDING) == 1


async def test_a_password_account_cannot_use_an_identity_it_has_not_linked(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    await oauth_account(client)  # an unrelated account holding the identity
    user = await register(client)
    proof = await reauth_proof(client, user.headers, "vk_id", SUBJECT)
    resp = await delete_with(client, user.headers, proof)
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_provider_token"
    assert await count(engine, "users") == 2
    assert await scalar(engine, NOT_PENDING) == 2


async def test_the_password_form_is_unchanged_and_a_linked_provider_also_works(
    client: AsyncClient,
) -> None:
    user = await register(client)
    wrong = await delete_with(client, user.headers, {"password": "wrong pass 1"})
    assert (wrong.status_code, wrong.json()["error"]["code"]) == (401, "invalid_password")
    assert (await link(client, user.headers, "yandex_id", "linked-one")).status_code == 201
    proof = await reauth_proof(client, user.headers, "yandex_id", "linked-one")
    assert (await delete_with(client, user.headers, proof)).status_code == 204


async def test_without_redis_the_assertion_form_is_a_503_and_deletes_nothing(
    client: AsyncClient,
    engine: AsyncEngine,
    redis_outage: Callable[[], AbstractAsyncContextManager[None]],
) -> None:
    headers = bearer(await oauth_account(client))
    proof = await reauth_proof(client, headers, "vk_id", SUBJECT)
    async with redis_outage():
        resp = await delete_with(client, headers, proof)
    assert resp.status_code == 503
    assert resp.json()["error"]["code"] == "provider_unreachable"
    assert await scalar(engine, NOT_PENDING) == 1


async def test_a_passwordless_account_can_be_restored_after_a_provider_deletion(
    client: AsyncClient,
) -> None:
    headers = bearer(await oauth_account(client))
    proof = await reauth_proof(client, headers, "vk_id", SUBJECT)
    assert (await delete_with(client, headers, proof)).status_code == 204
    # The assertion alone restores nothing: ticket plus the mailed code (ADR 0010).
    pending = await sign_in(client, email=EMAIL)
    assert pending.status_code == 403
    ticket = pending.json()["error"]["details"]["restore_ticket"]
    assert (await restore(client, ticket, None)).status_code == 401
    restored = await restore(client, ticket, last_code(client, EMAIL, "restore_account"))
    assert restored.status_code == 200, restored.text
    me = (await client.get("/v1/me", headers=bearer(restored.json()))).json()
    assert me["has_password"] is False
    assert (await sign_in(client, email=EMAIL)).status_code == 200  # signs in again
    assert len(sent_to(client, EMAIL, "account_restored")) == 1


# --- POST /v1/me/export ---------------------------------------------------------------------


@pytest.mark.usefixtures("export_on")
async def test_a_passwordless_account_exports_its_data_with_a_provider_assertion(
    client: AsyncClient, maker: async_sessionmaker[AsyncSession], settings: Settings
) -> None:
    tokens = await oauth_account(client)
    headers = bearer(tokens)
    proof = await reauth_proof(client, headers, "vk_id", SUBJECT)
    resp = await export_with(client, headers, proof)
    assert resp.status_code == 202, resp.text
    assert len(sent_to(client, EMAIL, "export_requested")) == 1
    report = await run_builder(maker, settings, datetime.now(UTC))
    assert report.built == 1
    user_id = (await client.get("/v1/me", headers=headers)).json()["id"]
    downloaded = await download_export(client, as_user(tokens, user_id), resp.json()["id"])
    assert downloaded.status_code == 200
    assert downloaded.content[:2] == b"PK"


@pytest.mark.usefixtures("export_on")
@pytest.mark.parametrize("case", BAD_CASES)
async def test_a_bad_assertion_does_not_export(
    client: AsyncClient, engine: AsyncEngine, case: str
) -> None:
    headers = bearer(await oauth_account(client))
    proof = await bad_proof(client, headers, case)
    resp = await export_with(client, headers, proof)
    assert resp.status_code == 401, resp.text
    assert resp.json()["error"]["code"] == "invalid_provider_token"
    assert await count(engine, "data_exports") == 0
    assert sent_to(client, EMAIL, "export_requested") == []


@pytest.mark.usefixtures("export_on")
async def test_the_export_needs_exactly_one_proof(client: AsyncClient, engine: AsyncEngine) -> None:
    headers = bearer(await oauth_account(client))
    proof = await reauth_proof(client, headers, "vk_id", SUBJECT)
    for body in (None, {}, {"password": "pw", **proof}):
        assert (await export_with(client, headers, body)).status_code == 422
    assert await count(engine, "data_exports") == 0


# --- rights survive the feature switch ---------------------------------------------------------


async def test_deletion_and_export_with_a_linked_provider_work_with_the_flag_off(
    client: AsyncClient,
    engine: AsyncEngine,
    monkeypatch: pytest.MonkeyPatch,
    settings: Settings,
) -> None:
    headers = bearer(await oauth_account(client))
    monkeypatch.setattr(settings, "feature_oauth", False)
    monkeypatch.setattr(settings, "feature_data_export", True)
    # Only the reauth nonce is still issued; every other OAuth route stays 404.
    other = await client.post("/v1/auth/oauth/nonce", json={"purpose": "link"}, headers=headers)
    assert other.status_code == 404
    export = await export_with(
        client, headers, await reauth_proof(client, headers, "vk_id", SUBJECT)
    )
    assert export.status_code == 202, export.text
    proof = await reauth_proof(client, headers, "vk_id", SUBJECT)
    assert (await delete_with(client, headers, proof)).status_code == 204
    assert await scalar(engine, "SELECT deletion_requested_at IS NOT NULL FROM users") is True
