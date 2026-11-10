"""Apple's token endpoint from the server (ADR 0017 section 9): the ES256 client secret, the
authorization-code exchange and the revocation, through ``httpx.MockTransport``. No database."""

from __future__ import annotations

import logging
import uuid
from datetime import timedelta

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from pydantic import ValidationError

from app.oauth.apple_key import load_apple_key
from app.oauth.apple_tokens import (
    APPLE_REVOKE_URL,
    APPLE_TOKEN_URL,
    AppleTokenClient,
    AppleTokenError,
)
from app.services.data_encryption import DataKeyring, DecryptionError
from app.services.provider_tokens import REFRESH_PURPOSE, ProviderTokens
from tests.conftest import make_settings
from tests.oauth_real_helpers import (
    APPLE_CLIENT_ID,
    APPLE_ISSUER,
    APPLE_KEY_ID,
    APPLE_PRIVATE_KEY_PEM,
    APPLE_SETTINGS,
    APPLE_TEAM_ID,
    CODE,
    NOW,
    REFRESH_TOKEN,
    timeout,
)
from tests.oauth_real_helpers import (
    AppleEndpoints as Apple,
)

SETTINGS = make_settings(**APPLE_SETTINGS)


# --- the client secret ------------------------------------------------------------------------


async def test_the_client_secret_is_an_es256_jwt_for_apple() -> None:
    secret = await Apple().client().client_secret(NOW)
    header = jwt.get_unverified_header(secret)
    assert (header["alg"], header["kid"]) == ("ES256", APPLE_KEY_ID)
    public = serialization.load_pem_private_key(APPLE_PRIVATE_KEY_PEM.encode(), None).public_key()
    body = jwt.decode(
        secret, public, algorithms=["ES256"], audience=APPLE_ISSUER, options={"verify_exp": False}
    )
    assert body["iss"] == APPLE_TEAM_ID
    assert body["sub"] == APPLE_CLIENT_ID
    assert body["iat"] == int(NOW.timestamp())


async def test_the_client_secret_lives_at_most_six_months() -> None:
    ttl = SETTINGS.oauth_apple_client_secret_ttl_seconds
    body = jwt.decode(
        await Apple().client().client_secret(NOW), options={"verify_signature": False}
    )
    assert body["exp"] - body["iat"] == ttl
    assert ttl <= 15_777_000


def test_a_ttl_above_six_months_is_refused() -> None:
    with pytest.raises(ValidationError):
        make_settings(region="eu", oauth_apple_client_secret_ttl_seconds=15_777_001)


async def test_the_client_secret_is_cached_and_renewed_before_it_runs_out() -> None:
    client = Apple().client()
    ttl = SETTINGS.oauth_apple_client_secret_ttl_seconds
    first = await client.client_secret(NOW)
    assert await client.client_secret(NOW + timedelta(seconds=ttl // 2 - 1)) == first
    renewed = await client.client_secret(NOW + timedelta(seconds=ttl // 2))
    assert renewed != first
    assert jwt.decode(renewed, options={"verify_signature": False})["exp"] > int(
        (NOW + timedelta(seconds=ttl // 2)).timestamp()
    )


def test_no_client_without_the_four_settings() -> None:
    http = httpx.AsyncClient()
    assert AppleTokenClient.from_settings(make_settings(region="eu"), http) is None
    partial = make_settings(region="eu", oauth_apple_client_id=APPLE_CLIENT_ID)
    assert AppleTokenClient.from_settings(partial, http) is None


def test_a_key_that_is_not_a_pem_leaves_apple_off_without_echoing_it(
    capsys: pytest.CaptureFixture[str],
) -> None:
    settings = make_settings(
        region="eu",
        oauth_apple_client_id=APPLE_CLIENT_ID,
        oauth_apple_team_id=APPLE_TEAM_ID,
        oauth_apple_key_id=APPLE_KEY_ID,
        oauth_apple_private_key="TOP-SECRET-NOT-A-KEY",
    )
    assert AppleTokenClient.from_settings(settings, httpx.AsyncClient()) is None
    out = capsys.readouterr()
    assert "TOP-SECRET" not in out.out + out.err


def test_a_key_of_another_curve_or_type_is_refused() -> None:
    from cryptography.hazmat.primitives.asymmetric import ec, rsa

    for key in (
        rsa.generate_private_key(public_exponent=65537, key_size=2048),
        ec.generate_private_key(ec.SECP384R1()),
    ):
        pem = key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        ).decode()
        assert load_apple_key(pem) is None
    assert load_apple_key(APPLE_PRIVATE_KEY_PEM) is not None


async def test_the_key_is_parsed_once_and_signing_runs_off_the_event_loop() -> None:
    import threading

    client = Apple().client()
    seen: list[str] = []
    real_sign = client._sign

    def spy(now: object) -> str:
        seen.append(threading.current_thread().name)
        return real_sign(now)  # type: ignore[arg-type]

    client._sign = spy  # type: ignore[method-assign]
    await client.client_secret(NOW)
    assert seen
    assert seen[0] != threading.main_thread().name


# --- the exchange -----------------------------------------------------------------------------


async def test_the_code_is_exchanged_with_the_client_secret() -> None:
    apple = Apple()
    result = await apple.client().exchange_code(CODE, NOW)
    assert result.refresh_token == REFRESH_TOKEN
    assert result.subject == "provider-subject-1"
    [(url, form)] = apple.calls
    assert url == APPLE_TOKEN_URL
    assert form["grant_type"] == "authorization_code"
    assert form["code"] == CODE
    assert form["client_id"] == APPLE_CLIENT_ID
    assert jwt.get_unverified_header(form["client_secret"])["alg"] == "ES256"


@pytest.mark.parametrize(
    "response",
    [
        httpx.Response(400, json={"error": "invalid_grant"}),
        httpx.Response(500),
        httpx.Response(200, text="not json"),
        httpx.Response(200, json={"id_token": "x"}),  # no refresh token
        httpx.Response(200, json={"refresh_token": ""}),
        httpx.Response(200, json={"refresh_token": 12}),
        httpx.Response(200, json=["list"]),
    ],
)
async def test_a_failed_exchange_is_an_error(response: httpx.Response) -> None:
    apple = Apple()
    apple.token_response = response
    with pytest.raises(AppleTokenError):
        await apple.client().exchange_code(CODE, NOW)


async def test_a_timeout_in_the_exchange_is_an_error() -> None:
    http = httpx.AsyncClient(transport=httpx.MockTransport(timeout))
    client = AppleTokenClient.from_settings(SETTINGS, http)
    assert client is not None
    with pytest.raises(AppleTokenError):
        await client.exchange_code(CODE, NOW)


async def test_an_exchange_without_an_id_token_has_no_subject() -> None:
    apple = Apple()
    apple.token_response = httpx.Response(200, json={"refresh_token": REFRESH_TOKEN})
    assert (await apple.client().exchange_code(CODE, NOW)).subject is None


# --- revoke -----------------------------------------------------------------------------------


async def test_revoke_sends_the_refresh_token_with_the_client_secret() -> None:
    apple = Apple()
    await apple.client().revoke(REFRESH_TOKEN, NOW)
    [(url, form)] = apple.calls
    assert url == APPLE_REVOKE_URL
    assert form["token"] == REFRESH_TOKEN
    assert form["token_type_hint"] == "refresh_token"
    assert form["client_id"] == APPLE_CLIENT_ID


async def test_a_revoke_refusal_is_an_error() -> None:
    apple = Apple()
    apple.revoke_responses = [httpx.Response(400)]
    with pytest.raises(AppleTokenError):
        await apple.client().revoke(REFRESH_TOKEN, NOW)


# --- sealing and the retry --------------------------------------------------------------------


def tokens_for(apple: Apple) -> ProviderTokens:
    return ProviderTokens(apple.client(), DataKeyring.from_settings(SETTINGS))


async def test_the_refresh_token_is_sealed_with_the_identity_id_and_has_no_plaintext() -> None:
    apple = Apple()
    tokens = tokens_for(apple)
    identity_id = uuid.uuid4()
    sealed = await tokens.exchange_and_seal("apple", CODE, "provider-subject-1", identity_id, NOW)
    assert sealed is not None
    assert REFRESH_TOKEN.encode() not in sealed
    keyring = DataKeyring.from_settings(SETTINGS)
    assert keyring is not None
    assert keyring.decrypt(REFRESH_PURPOSE, identity_id, sealed) == REFRESH_TOKEN.encode()


async def test_a_sealed_token_is_bound_to_its_identity() -> None:
    tokens = tokens_for(Apple())
    sealed = await tokens.exchange_and_seal("apple", CODE, "provider-subject-1", uuid.uuid4(), NOW)
    assert sealed is not None
    keyring = DataKeyring.from_settings(SETTINGS)
    assert keyring is not None
    with pytest.raises(DecryptionError):
        keyring.decrypt(REFRESH_PURPOSE, uuid.uuid4(), sealed)


async def test_a_code_of_another_apple_user_is_dropped() -> None:
    apple = Apple()
    apple.token_response = httpx.Response(
        200, json={"refresh_token": REFRESH_TOKEN, "id_token": apple.id_token("someone-else")}
    )
    sealed = await tokens_for(apple).exchange_and_seal(
        "apple", CODE, "provider-subject-1", uuid.uuid4(), NOW
    )
    assert sealed is None


async def test_a_failed_exchange_stores_nothing_and_never_raises() -> None:
    apple = Apple()
    apple.token_response = httpx.Response(500)
    sealed = await tokens_for(apple).exchange_and_seal(
        "apple", CODE, "provider-subject-1", uuid.uuid4(), NOW
    )
    assert sealed is None


async def test_other_providers_and_missing_codes_do_nothing() -> None:
    apple = Apple()
    tokens = tokens_for(apple)
    assert await tokens.exchange_and_seal("google", CODE, "s", uuid.uuid4(), NOW) is None
    assert await tokens.exchange_and_seal("apple", None, "s", uuid.uuid4(), NOW) is None
    assert apple.calls == []


async def test_without_a_keyring_nothing_is_exchanged() -> None:
    apple = Apple()
    tokens = ProviderTokens(apple.client(), None)
    assert await tokens.exchange_and_seal("apple", CODE, "s", uuid.uuid4(), NOW) is None
    assert apple.calls == []


async def test_revoke_decrypts_and_calls_apple_once_on_success() -> None:
    apple = Apple()
    tokens = tokens_for(apple)
    identity_id = uuid.uuid4()
    sealed = await tokens.exchange_and_seal("apple", CODE, "provider-subject-1", identity_id, NOW)
    apple.calls.clear()
    assert await tokens.revoke("apple", identity_id, sealed, NOW) is True
    [(url, form)] = apple.calls
    assert url == APPLE_REVOKE_URL
    assert form["token"] == REFRESH_TOKEN


async def test_revoke_retries_once_then_gives_up() -> None:
    apple = Apple()
    tokens = tokens_for(apple)
    identity_id = uuid.uuid4()
    sealed = await tokens.exchange_and_seal("apple", CODE, "provider-subject-1", identity_id, NOW)
    apple.calls.clear()
    apple.revoke_responses = [httpx.Response(500), httpx.Response(500), httpx.Response(200)]
    assert await tokens.revoke("apple", identity_id, sealed, NOW) is False
    assert len(apple.calls) == 2  # one try and one retry, no more


async def test_revoke_succeeds_on_the_retry() -> None:
    apple = Apple()
    tokens = tokens_for(apple)
    identity_id = uuid.uuid4()
    sealed = await tokens.exchange_and_seal("apple", CODE, "provider-subject-1", identity_id, NOW)
    apple.revoke_responses = [httpx.Response(500)]
    assert await tokens.revoke("apple", identity_id, sealed, NOW) is True


async def test_revoke_with_nothing_stored_or_a_foreign_blob_is_a_quiet_false() -> None:
    apple = Apple()
    tokens = tokens_for(apple)
    assert await tokens.revoke("apple", uuid.uuid4(), None, NOW) is False
    assert await tokens.revoke("apple", uuid.uuid4(), b"\x01" + b"x" * 40, NOW) is False
    assert await tokens.revoke("google", uuid.uuid4(), b"x", NOW) is False
    assert apple.calls == []


async def test_no_token_code_or_secret_reaches_the_logs(
    caplog: pytest.LogCaptureFixture, capsys: pytest.CaptureFixture[str]
) -> None:
    caplog.set_level(logging.DEBUG)
    apple = Apple()
    apple.token_response = httpx.Response(500, text=f"{REFRESH_TOKEN} {CODE}")
    tokens = tokens_for(apple)
    await tokens.exchange_and_seal("apple", CODE, "provider-subject-1", uuid.uuid4(), NOW)
    good = tokens_for(Apple())
    identity_id = uuid.uuid4()
    sealed = await good.exchange_and_seal("apple", CODE, "provider-subject-1", identity_id, NOW)
    failing = Apple()
    failing.revoke_responses = [httpx.Response(500, text=REFRESH_TOKEN)] * 2
    await tokens_for(failing).revoke("apple", identity_id, sealed, NOW)
    out = capsys.readouterr()
    everything = caplog.text + out.out + out.err
    for secret in (REFRESH_TOKEN, CODE, "provider-subject-1", APPLE_PRIVATE_KEY_PEM[:40]):
        assert secret not in everything
