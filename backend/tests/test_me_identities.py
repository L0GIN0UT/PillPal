"""The identities routes: list, link, unlink (ADR 0017 section 6), re-auth"""

from __future__ import annotations

import uuid

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from tests.grace_helpers import count, scalar, sent_to
from tests.helpers import register
from tests.identity_helpers import (
    IDENTITIES_URL,
    identities,
    link,
    link_body,
    reauth_proof,
    unlink,
)
from tests.oauth_helpers import SUBJECT, bearer, oauth_account, sign_in

pytestmark = pytest.mark.usefixtures("oauth_on")

NEW_SUBJECT = "yandex-subject-secret-42"
WRONG_PASSWORD = {"password": "wrong pass 1"}

# --- list -----------------------------------------------------------------------------------


async def test_the_list_shows_providers_and_never_the_subject(client: AsyncClient) -> None:
    tokens = await oauth_account(client)
    resp = await client.get(IDENTITIES_URL, headers=bearer(tokens))
    assert resp.status_code == 200
    [item] = resp.json()["items"]
    assert item["provider"] == "vk_id"
    assert item["email_at_link"] == "oauth-user@example.com"
    assert set(item) == {"id", "provider", "email_at_link", "created_at", "last_used_at"}
    assert SUBJECT not in resp.text


async def test_a_password_account_has_no_identities(client: AsyncClient) -> None:
    user = await register(client)
    assert await identities(client, user.headers) == []


async def test_the_list_is_scoped_to_the_caller(client: AsyncClient) -> None:
    await oauth_account(client, sub="someone-else", email="other@example.com")
    user = await register(client)
    assert await identities(client, user.headers) == []


async def test_every_identity_route_needs_a_token(client: AsyncClient) -> None:
    some_id = uuid.uuid4()
    assert (await client.get(IDENTITIES_URL)).status_code == 401
    assert (await client.post(IDENTITIES_URL, json={})).status_code == 401
    assert (await client.request("DELETE", f"{IDENTITIES_URL}/{some_id}")).status_code == 401


# --- link -----------------------------------------------------------------------------------


async def test_link_with_the_password_creates_the_identity_and_mails_a_notice(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    resp = await link(client, user.headers, "yandex_id", NEW_SUBJECT, email="Typed@Example.com")
    assert resp.status_code == 201, resp.text
    body = resp.json()
    assert body["provider"] == "yandex_id"
    assert body["email_at_link"] == "typed@example.com"
    assert NEW_SUBJECT not in resp.text
    assert [i["id"] for i in await identities(client, user.headers)] == [body["id"]]
    assert await scalar(engine, "SELECT subject FROM auth_identities") == NEW_SUBJECT
    [mail] = sent_to(client, user.email, "identity_linked")
    assert mail.provider == "yandex_id"
    assert NEW_SUBJECT not in repr(mail)  # the provider name only


async def test_the_linked_identity_signs_in_to_the_same_account(client: AsyncClient) -> None:
    user = await register(client)
    assert (await link(client, user.headers, "yandex_id", NEW_SUBJECT)).status_code == 201
    resp = await sign_in(client, "yandex_id", NEW_SUBJECT)
    assert resp.status_code == 200, resp.text
    me = await client.get("/v1/me", headers=bearer(resp.json()))
    assert me.json()["id"] == user.id


async def test_a_replay_of_the_same_identity_is_200_and_mails_nothing_new(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    first = await link(client, user.headers, "yandex_id", NEW_SUBJECT)
    again = await link(client, user.headers, "yandex_id", NEW_SUBJECT)
    assert (first.status_code, again.status_code) == (201, 200)
    assert again.json()["id"] == first.json()["id"]
    assert await count(engine, "auth_identities") == 1
    assert len(sent_to(client, user.email, "identity_linked")) == 1


async def test_an_identity_of_another_account_is_a_409_and_changes_nothing(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    await oauth_account(client, "yandex_id", NEW_SUBJECT, email="holder@example.com")
    user = await register(client)
    resp = await link(client, user.headers, "yandex_id", NEW_SUBJECT)
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "identity_in_use"
    assert await count(engine, "auth_identities") == 1
    assert sent_to(client, user.email, "identity_linked") == []
    assert "holder@example.com" not in resp.text


async def test_link_needs_exactly_one_proof(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    body = await link_body(client, user.headers, "yandex_id", NEW_SUBJECT, {})
    assert (await client.post(IDENTITIES_URL, json=body, headers=user.headers)).status_code == 422
    other = await reauth_proof(client, user.headers, "vk_id", "whoever")
    both = {**body, "password": user.password, **other}
    assert (await client.post(IDENTITIES_URL, json=both, headers=user.headers)).status_code == 422
    assert await count(engine, "auth_identities") == 0


async def test_link_with_a_wrong_password_is_a_401_and_changes_nothing(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    resp = await link(client, user.headers, "yandex_id", NEW_SUBJECT, WRONG_PASSWORD)
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_password"
    assert await count(engine, "auth_identities") == 0
    assert sent_to(client, user.email, "identity_linked") == []


async def test_a_passwordless_account_links_with_a_linked_providers_assertion(
    client: AsyncClient,
) -> None:
    headers = bearer(await oauth_account(client))
    proof = await reauth_proof(client, headers, "vk_id", SUBJECT)
    resp = await link(client, headers, "yandex_id", NEW_SUBJECT, proof)
    assert resp.status_code == 201, resp.text
    assert {i["provider"] for i in await identities(client, headers)} == {"vk_id", "yandex_id"}


@pytest.mark.parametrize(
    "case", ["stale", "wrong_purpose", "not_linked", "other_accounts_identity", "replayed"]
)
async def test_a_bad_reauth_assertion_links_nothing(
    client: AsyncClient, engine: AsyncEngine, case: str
) -> None:
    headers = bearer(await oauth_account(client))
    await oauth_account(client, "vk_id", "another-subject", email="another@example.com")
    if case == "stale":
        proof = await reauth_proof(client, headers, "vk_id", SUBJECT, age_seconds=301)
    elif case == "wrong_purpose":
        proof = await reauth_proof(client, headers, "vk_id", SUBJECT, purpose="link")
    elif case == "not_linked":
        proof = await reauth_proof(client, headers, "vk_id", "never-linked")
    elif case == "other_accounts_identity":
        proof = await reauth_proof(client, headers, "vk_id", "another-subject")
    else:
        proof = await reauth_proof(client, headers, "vk_id", SUBJECT, jti="same-jti")
        assert (await link(client, headers, "yandex_id", "first", proof)).status_code == 201
        proof = await reauth_proof(client, headers, "vk_id", SUBJECT, jti="same-jti")
    resp = await link(client, headers, "yandex_id", NEW_SUBJECT, proof)
    assert resp.status_code == 401, resp.text
    assert resp.json()["error"]["code"] == "invalid_provider_token"
    linked = await scalar(
        engine, "SELECT count(*) FROM auth_identities WHERE provider = 'yandex_id'"
    )
    assert linked == (1 if case == "replayed" else 0)


async def test_a_reauth_assertion_under_the_age_limit_is_accepted(client: AsyncClient) -> None:
    headers = bearer(await oauth_account(client))
    proof = await reauth_proof(client, headers, "vk_id", SUBJECT, age_seconds=240)
    assert (await link(client, headers, "yandex_id", NEW_SUBJECT, proof)).status_code == 201


async def test_the_new_assertion_needs_a_link_nonce_and_is_single_use(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    wrong = await link(client, user.headers, "yandex_id", NEW_SUBJECT, purpose="sign_in")
    assert wrong.status_code == 401
    assert wrong.json()["error"]["code"] == "invalid_provider_token"
    proof = {"password": user.password}
    body = await link_body(client, user.headers, "yandex_id", NEW_SUBJECT, proof)
    assert (await client.post(IDENTITIES_URL, json=body, headers=user.headers)).status_code == 201
    replay = await client.post(IDENTITIES_URL, json=body, headers=user.headers)
    assert replay.status_code == 401  # the nonce and the assertion are spent
    assert await count(engine, "auth_identities") == 1


async def test_link_validates_the_body(client: AsyncClient) -> None:
    user = await register(client)
    good = {"provider": "vk_id", "platform": "android", "assertion": "x", "password": "p"}
    for body in (
        {},
        {**good, "provider": "github"},
        {**good, "platform": "web"},
        {**good, "assertion": ""},
        {**good, "unknown": 1},
    ):
        resp = await client.post(IDENTITIES_URL, json=body, headers=user.headers)
        assert resp.status_code == 422, body


async def test_a_provider_the_region_does_not_offer_is_404(client: AsyncClient) -> None:
    user = await register(client)
    resp = await link(client, user.headers, "apple", NEW_SUBJECT, platform="ios")
    assert resp.status_code == 404


async def test_link_is_404_while_the_feature_is_off(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    user = await register(client)
    proof = {"password": user.password}
    body = await link_body(client, user.headers, "yandex_id", NEW_SUBJECT, proof)
    monkeypatch.setattr(settings, "feature_oauth", False)
    resp = await client.post(IDENTITIES_URL, json=body, headers=user.headers)
    assert resp.status_code == 404


async def test_a_provider_timeout_while_linking_is_503(client: AsyncClient) -> None:
    user = await register(client)
    resp = await link(client, user.headers, "yandex_id", NEW_SUBJECT, fail="unreachable")
    assert resp.status_code == 503
    assert resp.json()["error"]["code"] == "provider_unreachable"


async def test_link_is_limited_per_account(client: AsyncClient) -> None:
    user = await register(client)
    body = {"provider": "yandex_id", "platform": "android", "assertion": "x", **WRONG_PASSWORD}
    statuses = [
        (await client.post(IDENTITIES_URL, json=body, headers=user.headers)).status_code
        for _ in range(21)
    ]
    assert set(statuses[:20]) == {401}
    assert statuses[20] == 429


# --- unlink ---------------------------------------------------------------------------------


async def test_unlink_with_the_password_removes_the_identity_and_mails_a_notice(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    created = await link(client, user.headers, "yandex_id", NEW_SUBJECT)
    resp = await unlink(client, user.headers, created.json()["id"], {"password": user.password})
    assert resp.status_code == 204
    assert await identities(client, user.headers) == []
    assert await count(engine, "auth_identities") == 0
    [mail] = sent_to(client, user.email, "identity_unlinked")
    assert mail.provider == "yandex_id"
    assert NEW_SUBJECT not in repr(mail)


async def test_an_unlinked_identity_no_longer_signs_in(client: AsyncClient) -> None:
    user = await register(client)
    created = await link(client, user.headers, "yandex_id", NEW_SUBJECT)
    await unlink(client, user.headers, created.json()["id"], {"password": user.password})
    resp = await sign_in(client, "yandex_id", NEW_SUBJECT)
    assert resp.status_code == 409
    assert "access_token" not in resp.text


async def test_the_last_sign_in_method_of_a_passwordless_account_stays(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    headers = bearer(await oauth_account(client))
    [only] = await identities(client, headers)
    proof = await reauth_proof(client, headers, "vk_id", SUBJECT)
    resp = await unlink(client, headers, only["id"], proof)
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "last_sign_in_method"
    assert await count(engine, "auth_identities") == 1
    assert sent_to(client, "oauth-user@example.com", "identity_unlinked") == []


async def test_a_passwordless_account_may_drop_one_of_two_identities(client: AsyncClient) -> None:
    headers = bearer(await oauth_account(client))
    proof = await reauth_proof(client, headers, "vk_id", SUBJECT)
    created = await link(client, headers, "yandex_id", NEW_SUBJECT, proof)
    # Re-authenticating with the very identity that is removed is allowed: it is still linked.
    proof = await reauth_proof(client, headers, "yandex_id", NEW_SUBJECT)
    assert (await unlink(client, headers, created.json()["id"], proof)).status_code == 204
    assert [i["provider"] for i in await identities(client, headers)] == ["vk_id"]


async def test_a_password_counts_as_a_method_when_the_account_has_one(
    client: AsyncClient,
) -> None:
    user = await register(client)  # its only identity may go: the password stays
    created = await link(client, user.headers, "yandex_id", NEW_SUBJECT)
    assert (await unlink(client, user.headers, created.json()["id"])).status_code == 204


async def test_a_foreign_or_unknown_identity_is_404(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    other = await oauth_account(client, sub="someone-else", email="other@example.com")
    [theirs] = await identities(client, bearer(other))
    user = await register(client)
    for identity_id in (theirs["id"], uuid.uuid4()):
        resp = await unlink(client, user.headers, identity_id)
        assert resp.status_code == 404
    assert await count(engine, "auth_identities") == 1


async def test_unlink_needs_exactly_one_valid_proof(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    created = await link(client, user.headers, "yandex_id", NEW_SUBJECT)
    url = f"{IDENTITIES_URL}/{created.json()['id']}"
    for body in (None, {}, {"password": user.password, "reauth": {"provider": "vk_id"}}):
        resp = await client.request("DELETE", url, json=body, headers=user.headers)
        assert resp.status_code == 422, body
    wrong = await unlink(client, user.headers, created.json()["id"], WRONG_PASSWORD)
    assert wrong.status_code == 401
    assert wrong.json()["error"]["code"] == "invalid_password"
    assert await count(engine, "auth_identities") == 1


async def test_unlink_refuses_a_stale_reauth_assertion(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    headers = bearer(await oauth_account(client))
    proof = await reauth_proof(client, headers, "vk_id", SUBJECT)
    created = await link(client, headers, "yandex_id", NEW_SUBJECT, proof)
    stale = await reauth_proof(client, headers, "vk_id", SUBJECT, age_seconds=600)
    resp = await unlink(client, headers, created.json()["id"], stale)
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_provider_token"
    assert await count(engine, "auth_identities") == 2


async def test_unlink_is_limited_per_account(client: AsyncClient) -> None:
    user = await register(client)
    statuses = [
        (await unlink(client, user.headers, uuid.uuid4(), WRONG_PASSWORD)).status_code
        for _ in range(21)
    ]
    assert set(statuses[:20]) == {401}
    assert statuses[20] == 429
