"""VK ID and Yandex ID through the HTTP API with the real code verifiers (milestone 5.9, ADR 0017):
sign-in, the e-mail fallback, state binding, replay, outages, re-auth, link and unlink, logs."""

from __future__ import annotations

import logging
from typing import Any

import httpx
import pytest

from tests.grace_helpers import count
from tests.helpers import DEFAULT_PASSWORD, register
from tests.identity_helpers import IDENTITIES_URL, PASSWORD_PROOF, identities, unlink
from tests.oauth_code_flow_helpers import PROVIDERS, Codes, error_code
from tests.oauth_code_helpers import (
    ACCESS_TOKEN,
    DEVICE_ID,
    REFRESH_TOKEN,
    VERIFIER,
    VK_SECRET,
    VK_SUBJECT,
    YANDEX_SECRET,
    YANDEX_SUBJECT,
    timeout,
)
from tests.oauth_helpers import CONSENTS, bearer, new_nonce, sign_up, ticket_of

BOTH = pytest.mark.parametrize("name", PROVIDERS)
TOKEN_URL = {
    "vk_id": "https://id.vk.ru/oauth2/auth",
    "yandex_id": "https://oauth.yandex.ru/token",
}
SUBJECT = {"vk_id": VK_SUBJECT, "yandex_id": YANDEX_SUBJECT}
EMAIL = "code-user@example.com"


# --- sign-in and the e-mail fallback ----------


async def test_the_providers_are_offered_on_android_only(codes: Codes) -> None:
    android = await codes.client.get("/v1/auth/providers", params={"platform": "android"})
    ios = await codes.client.get("/v1/auth/providers", params={"platform": "ios"})
    assert [p["provider"] for p in android.json()["providers"]] == ["vk_id", "yandex_id"]
    assert ios.json()["providers"] == []


@BOTH
async def test_an_unknown_identity_gets_a_ticket_that_asks_for_an_address(
    codes: Codes, name: str
) -> None:
    resp = await codes.sign_in(name)
    ticket_of(resp)
    assert resp.json()["error"]["details"]["email_required"] is True


@BOTH
async def test_an_address_from_the_provider_is_still_not_verified(codes: Codes, name: str) -> None:
    codes.endpoints.email = "from-provider@example.com"
    resp = await codes.sign_in(name)
    ticket_of(resp)
    assert resp.json()["error"]["details"]["email_required"] is True


@BOTH
async def test_the_fallback_signs_up_with_a_mailed_code_and_a_pending_token(
    codes: Codes, name: str
) -> None:
    ticket = ticket_of(await codes.sign_in(name))
    resp = await sign_up(codes.client, ticket, email=EMAIL, consents=CONSENTS)
    assert resp.status_code == 202, resp.text
    assert resp.json()["pending_token"]
    assert "access_token" not in resp.text


@BOTH
async def test_a_known_identity_signs_in_again_with_a_new_code(codes: Codes, name: str) -> None:
    created = await codes.account(name)
    resp = await codes.sign_in(name)
    assert resp.status_code == 200, resp.text
    me = (await codes.client.get("/v1/me", headers=bearer(created))).json()
    assert (await codes.client.get("/v1/me", headers=bearer(resp.json()))).json()["id"] == me["id"]


async def test_the_address_of_an_existing_account_is_no_oracle(codes: Codes) -> None:
    await register(codes.client, email="taken@example.com")
    codes.endpoints.email = "taken@example.com"
    resp = await codes.sign_in("vk_id")
    # Not oauth_account_exists: the provider's address proves nothing, so it is not even compared.
    assert error_code(resp) == "oauth_signup_required"


# --- the state ----------


@BOTH
async def test_a_state_is_single_use(codes: Codes, name: str) -> None:
    nonce = await new_nonce(codes.client)
    assert (await codes.sign_in(name, nonce=nonce)).status_code == 409
    exchanges = len(codes.endpoints.to(TOKEN_URL[name]))
    again = await codes.sign_in(name, nonce=nonce)
    assert (again.status_code, error_code(again)) == (401, "invalid_provider_token")
    assert len(codes.endpoints.to(TOKEN_URL[name])) == exchanges  # refused before the exchange


@BOTH
@pytest.mark.parametrize("purpose", ["link", "reauth"])
async def test_a_state_of_another_purpose_is_refused_before_the_exchange(
    codes: Codes, name: str, purpose: str
) -> None:
    resp = await codes.sign_in(name, purpose=purpose)
    assert (resp.status_code, error_code(resp)) == (401, "invalid_provider_token")
    assert codes.endpoints.calls == []


@BOTH
async def test_an_unknown_state_is_refused_before_the_exchange(codes: Codes, name: str) -> None:
    resp = await codes.sign_in(name, nonce="never-issued-" + "x" * 30)
    assert resp.status_code == 401
    assert codes.endpoints.calls == []


@BOTH
async def test_a_code_is_single_use_even_with_a_new_state(codes: Codes, name: str) -> None:
    assert (await codes.sign_in(name, code="one-code")).status_code == 409
    again = await codes.sign_in(name, code="one-code")
    assert (again.status_code, error_code(again)) == (401, "invalid_provider_token")


# --- what the client may send ----------


@BOTH
async def test_a_client_access_token_is_not_a_field(codes: Codes, name: str) -> None:
    nonce = await new_nonce(codes.client)
    body = codes.body(name, nonce, access_token="client-side-token")
    resp = await codes.client.post(f"/v1/auth/oauth/{name}/sign-in", json=body)
    assert resp.status_code == 422
    assert codes.endpoints.calls == []


@BOTH
async def test_a_missing_verifier_is_refused_without_an_exchange(codes: Codes, name: str) -> None:
    nonce = await new_nonce(codes.client)
    body = codes.body(name, nonce)
    del body["code_verifier"]
    resp = await codes.client.post(f"/v1/auth/oauth/{name}/sign-in", json=body)
    assert (resp.status_code, error_code(resp)) == (401, "invalid_provider_token")
    assert codes.endpoints.calls == []


async def test_vk_needs_its_device_id_and_validates_its_shape(codes: Codes) -> None:
    nonce = await new_nonce(codes.client)
    body = codes.body("vk_id", nonce)
    del body["device_id"]
    missing = await codes.client.post("/v1/auth/oauth/vk_id/sign-in", json=body)
    assert (missing.status_code, error_code(missing)) == (401, "invalid_provider_token")
    nonce = await new_nonce(codes.client)
    odd = await codes.sign_in("vk_id", nonce=nonce, device_id="has a space")
    assert odd.status_code == 422


@BOTH
async def test_the_ios_platform_is_not_found(codes: Codes, name: str) -> None:
    nonce = await new_nonce(codes.client)
    resp = await codes.client.post(
        f"/v1/auth/oauth/{name}/sign-in", json=codes.body(name, nonce, platform="ios")
    )
    assert resp.status_code == 404
    assert codes.endpoints.calls == []


# --- provider failures ----------


@BOTH
async def test_a_pkce_mismatch_or_provider_refusal_is_a_401(codes: Codes, name: str) -> None:
    codes.endpoints.replace[TOKEN_URL[name]] = httpx.Response(400, json={"error": "invalid_grant"})
    resp = await codes.sign_in(name)
    assert (resp.status_code, error_code(resp)) == (401, "invalid_provider_token")
    assert "invalid_grant" not in resp.text  # the provider's text is never echoed


@BOTH
async def test_a_provider_timeout_is_a_503(codes: Codes, name: str) -> None:
    codes.endpoints.replace[TOKEN_URL[name]] = timeout
    resp = await codes.sign_in(name)
    assert (resp.status_code, error_code(resp)) == (503, "provider_unreachable")


@BOTH
async def test_nothing_is_created_by_a_failed_exchange(
    codes: Codes, name: str, engine: Any
) -> None:
    codes.endpoints.replace[TOKEN_URL[name]] = httpx.Response(400, json={"error": "invalid_grant"})
    await codes.sign_in(name)
    assert await count(engine, "auth_identities") == 0
    assert await count(engine, "users") == 0


# --- re-authentication, link and unlink ----------


async def reauth_form(
    codes: Codes, name: str, headers: dict[str, str], **extra: Any
) -> dict[str, Any]:
    nonce = await new_nonce(codes.client, extra.pop("purpose", "reauth"), headers)
    return {"reauth": {"provider": name, **codes.body(name, nonce, **extra)}}


@BOTH
async def test_a_code_provider_account_deletes_itself_with_a_fresh_code(
    codes: Codes, name: str
) -> None:
    tokens = await codes.account(name)
    headers = bearer(tokens)
    form = await reauth_form(codes, name, headers)
    resp = await codes.client.request("DELETE", "/v1/me", json=form, headers=headers)
    assert resp.status_code == 204, resp.text


@BOTH
async def test_a_code_spent_at_sign_in_is_no_reauth_proof(codes: Codes, name: str) -> None:
    tokens = await codes.account(name)
    headers = bearer(tokens)
    assert (await codes.sign_in(name, code="spent-code")).status_code == 200
    form = await reauth_form(codes, name, headers, code="spent-code")
    resp = await codes.client.request("DELETE", "/v1/me", json=form, headers=headers)
    assert (resp.status_code, error_code(resp)) == (401, "invalid_provider_token")


@BOTH
async def test_a_reauth_with_a_state_of_another_purpose_is_a_401(codes: Codes, name: str) -> None:
    tokens = await codes.account(name)
    headers = bearer(tokens)
    form = await reauth_form(codes, name, headers, purpose="link")
    resp = await codes.client.request("DELETE", "/v1/me", json=form, headers=headers)
    assert (resp.status_code, error_code(resp)) == (401, "invalid_provider_token")


async def test_a_reauth_with_the_identity_of_another_account_is_a_401(codes: Codes) -> None:
    mine = await codes.account("vk_id")
    codes.endpoints.vk_subject = "777000"  # another VK user signs up
    await codes.account("vk_id", email="other-person@example.com")
    form = await reauth_form(codes, "vk_id", bearer(mine))  # still "777000": not mine
    resp = await codes.client.request("DELETE", "/v1/me", json=form, headers=bearer(mine))
    assert (resp.status_code, error_code(resp)) == (401, "invalid_provider_token")


@BOTH
async def test_link_and_unlink_with_a_password_proof(codes: Codes, name: str) -> None:
    user = await register(codes.client)
    nonce = await new_nonce(codes.client, "link", user.headers)
    body = {"provider": name, **codes.body(name, nonce), **PASSWORD_PROOF}
    linked = await codes.client.post(IDENTITIES_URL, json=body, headers=user.headers)
    assert linked.status_code == 201, linked.text
    listed = await identities(codes.client, user.headers)
    assert [item["provider"] for item in listed] == [name]
    assert SUBJECT[name] not in linked.text  # the subject is never returned
    # Signing in through the provider now opens this account.
    resp = await codes.sign_in(name)
    assert resp.status_code == 200, resp.text
    removed = await unlink(codes.client, user.headers, listed[0]["id"])
    assert removed.status_code == 204, removed.text
    assert await identities(codes.client, user.headers) == []


async def test_an_identity_of_another_account_cannot_be_linked(codes: Codes) -> None:
    await codes.account("vk_id")
    user = await register(codes.client, email="second@example.com", password=DEFAULT_PASSWORD)
    nonce = await new_nonce(codes.client, "link", user.headers)
    body = {"provider": "vk_id", **codes.body("vk_id", nonce), **PASSWORD_PROOF}
    resp = await codes.client.post(IDENTITIES_URL, json=body, headers=user.headers)
    assert (resp.status_code, error_code(resp)) == (409, "identity_in_use")


async def test_link_needs_a_state_issued_for_link(codes: Codes, engine: Any) -> None:
    user = await register(codes.client)
    nonce = await new_nonce(codes.client, "sign_in", user.headers)
    body = {"provider": "yandex_id", **codes.body("yandex_id", nonce), **PASSWORD_PROOF}
    resp = await codes.client.post(IDENTITIES_URL, json=body, headers=user.headers)
    assert (resp.status_code, error_code(resp)) == (401, "invalid_provider_token")
    assert await count(engine, "auth_identities") == 0


# --- logs ----------


@BOTH
async def test_no_code_token_verifier_or_subject_reaches_the_logs(
    codes: Codes,
    name: str,
    caplog: pytest.LogCaptureFixture,
    capsys: pytest.CaptureFixture[str],
) -> None:
    caplog.set_level(logging.DEBUG)
    codes.endpoints.email = "provider-address@example.com"
    nonce = await new_nonce(codes.client)
    code = "log-check-code-0001"
    ticket = ticket_of(await codes.sign_in(name, nonce=nonce, code=code))
    await sign_up(codes.client, ticket, email="typed-address@example.com", consents=CONSENTS)
    codes.endpoints.replace[TOKEN_URL[name]] = httpx.Response(400, json={"error": "invalid_grant"})
    await codes.sign_in(name, code="log-check-code-0002")
    codes.endpoints.replace[TOKEN_URL[name]] = timeout
    await codes.sign_in(name, code="log-check-code-0003")
    captured = capsys.readouterr()
    seen = captured.out + captured.err + caplog.text
    secrets = (
        nonce,
        ticket,
        code,
        "log-check-code-000",
        VERIFIER,
        DEVICE_ID,
        ACCESS_TOKEN,
        REFRESH_TOKEN,
        VK_SECRET,
        YANDEX_SECRET,
        SUBJECT[name],
        "provider-address",
        "typed-address",
    )
    for secret in secrets:
        assert secret not in seen, "a secret reached the logs"
