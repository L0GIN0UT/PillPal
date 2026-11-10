"""VK ID and Yandex ID verifiers (milestone 5.9, ADR 0017 section 3): the server exchanges the
authorization code itself with PKCE, never takes an access token from the client and never
trusts an e-mail the provider documentation does not call verified. No database, no Redis."""

from __future__ import annotations

import hashlib
import logging
from collections.abc import AsyncIterator
from typing import Any

import httpx
import pytest

from app.errors import AppError
from app.oauth.base import IdentityProvider, VerifiedIdentity
from app.oauth.vk_id import VK_TOKEN_URL, VK_USER_INFO_URL, VkIdProvider
from app.oauth.yandex_id import YANDEX_INFO_URL, YANDEX_TOKEN_URL, YandexIdProvider
from tests.oauth_code_helpers import (
    ACCESS_TOKEN,
    CODE,
    DEVICE_ID,
    NOW,
    REFRESH_TOKEN,
    STATE,
    VERIFIER,
    VK_CLIENT_ID,
    VK_SECRET,
    VK_SUBJECT,
    YANDEX_CLIENT_ID,
    YANDEX_SECRET,
    YANDEX_SUBJECT,
    CodeEndpoints,
    settings_for,
    timeout,
)


@pytest.fixture
def endpoints() -> CodeEndpoints:
    return CodeEndpoints()


@pytest.fixture
async def http(endpoints: CodeEndpoints) -> AsyncIterator[httpx.AsyncClient]:
    async with httpx.AsyncClient(transport=endpoints.transport(), follow_redirects=False) as client:
        yield client


def make(name: str, http: httpx.AsyncClient, **settings: Any) -> IdentityProvider:
    built = settings_for(**settings)
    return VkIdProvider(built, http) if name == "vk_id" else YandexIdProvider(built, http)


async def verify(
    provider: IdentityProvider,
    *,
    code: str = CODE,
    nonce: str | None = STATE,
    verifier: str | None = VERIFIER,
    device_id: str | None = DEVICE_ID,
    platform: str = "android",
) -> VerifiedIdentity:
    return await provider.verify(
        code,
        nonce=nonce,
        platform=platform,
        code_verifier=verifier,
        device_id=device_id,
        now=NOW,
    )


async def refused(provider: IdentityProvider, status: int, error: str, **kwargs: Any) -> None:
    with pytest.raises(AppError) as caught:
        await verify(provider, **kwargs)
    assert (caught.value.status_code, caught.value.code) == (status, error)


BOTH = pytest.mark.parametrize("name", ["vk_id", "yandex_id"])
TOKEN_URL = {"vk_id": VK_TOKEN_URL, "yandex_id": YANDEX_TOKEN_URL}
INFO_URL = {"vk_id": VK_USER_INFO_URL, "yandex_id": YANDEX_INFO_URL}
SUBJECT = {"vk_id": VK_SUBJECT, "yandex_id": YANDEX_SUBJECT}


# --- the exchange -------------------------------------------------------------------------------


async def test_vk_exchanges_the_code_with_pkce_then_asks_for_the_user(
    http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    identity = await verify(make("vk_id", http))
    assert (identity.provider, identity.subject) == ("vk_id", VK_SUBJECT)
    [token_call] = endpoints.to(VK_TOKEN_URL)
    assert token_call.method == "POST"
    assert token_call.form == {
        "grant_type": "authorization_code",
        "code": CODE,
        "code_verifier": VERIFIER,
        "device_id": DEVICE_ID,
        "state": STATE,
        "client_id": VK_CLIENT_ID,
        "redirect_uri": f"vk{VK_CLIENT_ID}://vk.ru/blank.html",
        "service_token": VK_SECRET,
    }
    [info_call] = endpoints.to(VK_USER_INFO_URL)
    assert info_call.form == {"client_id": VK_CLIENT_ID, "access_token": ACCESS_TOKEN}
    assert [c.url for c in endpoints.calls] == [VK_TOKEN_URL, VK_USER_INFO_URL]


async def test_vk_uses_the_configured_redirect_uri(
    http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    provider = make("vk_id", http, oauth_vk_redirect_uri="https://example.com/vk-callback")
    await verify(provider)
    assert endpoints.to(VK_TOKEN_URL)[0].form["redirect_uri"] == "https://example.com/vk-callback"


async def test_yandex_exchanges_the_code_with_pkce_then_asks_for_the_user(
    http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    identity = await verify(make("yandex_id", http))
    assert (identity.provider, identity.subject) == ("yandex_id", YANDEX_SUBJECT)
    [token_call] = endpoints.to(YANDEX_TOKEN_URL)
    assert token_call.form == {
        "grant_type": "authorization_code",
        "code": CODE,
        "code_verifier": VERIFIER,
        "client_id": YANDEX_CLIENT_ID,
        "client_secret": YANDEX_SECRET,
    }
    [info_call] = endpoints.calls[1:]
    assert info_call.method == "GET"
    # The token travels in the header, never in the URL (it would reach access logs).
    assert info_call.headers["Authorization"] == f"OAuth {ACCESS_TOKEN}"
    assert ACCESS_TOKEN not in info_call.url


@BOTH
async def test_issued_at_is_the_exchange_time_and_the_assertion_id_is_a_hash(
    name: str, http: httpx.AsyncClient
) -> None:
    identity = await verify(make(name, http))
    assert identity.issued_at == NOW
    assert identity.expires_at > NOW
    assert identity.assertion_id == hashlib.sha256(CODE.encode()).hexdigest()
    assert CODE not in identity.assertion_id


@BOTH
async def test_the_provider_takes_a_state_like_a_nonce(name: str, http: httpx.AsyncClient) -> None:
    assert make(name, http).uses_nonce is True


# --- e-mail -------------------------------------------------------------------------------------


@BOTH
async def test_an_address_is_never_counted_as_verified(
    name: str, http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    # Neither provider's documentation calls its e-mail verified (VK ``verified`` is the blue
    # check mark of famous people): the address goes through the mailed-code fallback (Q7).
    endpoints.email = "  Person@Example.com "
    identity = await verify(make(name, http))
    assert identity.email == "person@example.com"
    assert identity.email_verified is False


@BOTH
async def test_no_address_is_none(name: str, http: httpx.AsyncClient) -> None:
    identity = await verify(make(name, http))
    assert (identity.email, identity.email_verified) == (None, False)


@BOTH
async def test_an_unusable_address_is_dropped(
    name: str, http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    endpoints.email = "not-an-address"
    assert (await verify(make(name, http))).email is None


# --- failures -----------------------------------------------------------------------------------


@BOTH
@pytest.mark.parametrize("status", [400, 401, 403, 404])
async def test_a_provider_refusal_is_a_401(
    name: str, status: int, http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    # A PKCE verifier that does not match the challenge, a spent or foreign code: all one answer.
    endpoints.replace[TOKEN_URL[name]] = httpx.Response(status, json={"error": "invalid_grant"})
    await refused(make(name, http), 401, "invalid_provider_token")
    assert endpoints.to(INFO_URL[name]) == []  # the user is not asked after a refusal


@BOTH
@pytest.mark.parametrize("status", [500, 502, 503, 429])
async def test_a_provider_outage_is_a_503(
    name: str, status: int, http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    endpoints.replace[TOKEN_URL[name]] = httpx.Response(status)
    await refused(make(name, http), 503, "provider_unreachable")


@BOTH
async def test_a_timeout_is_a_503(
    name: str, http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    endpoints.replace[TOKEN_URL[name]] = timeout
    await refused(make(name, http), 503, "provider_unreachable")


@BOTH
async def test_a_timeout_on_the_user_request_is_a_503(
    name: str, http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    endpoints.replace[INFO_URL[name]] = timeout
    await refused(make(name, http), 503, "provider_unreachable")


@BOTH
async def test_a_refusal_on_the_user_request_is_a_401(
    name: str, http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    endpoints.replace[INFO_URL[name]] = httpx.Response(401, json={"error": "invalid_token"})
    await refused(make(name, http), 401, "invalid_provider_token")


async def test_a_temporary_error_body_is_a_503(
    http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    body = {"error": "temporarily_unavailable"}
    endpoints.replace[VK_TOKEN_URL] = httpx.Response(400, json=body)
    await refused(make("vk_id", http), 503, "provider_unreachable")


@BOTH
@pytest.mark.parametrize(
    "response",
    [
        httpx.Response(200, text="<html>not json</html>"),
        httpx.Response(200, json=["a", "list"]),
        httpx.Response(200, json={}),
        httpx.Response(200, json={"error": "invalid_grant"}),
        httpx.Response(200, json={"access_token": ""}),
        httpx.Response(200, json={"access_token": 12345}),
        httpx.Response(302, headers={"Location": "https://evil.example/"}),
        httpx.Response(200, content=b"{" + b" " * 70_000 + b"}"),
        httpx.Response(200, json={"error": ["x"]}),
        httpx.Response(200, json={"error": {"nested": 1}}),
        httpx.Response(200, content=b"[" * 20_000 + b"]" * 20_000),  # RecursionError in json
        httpx.Response(200, content=b'"just a string"'),
        httpx.Response(200, content=b"12345"),
        httpx.Response(200, content=b"null"),
        httpx.Response(200, content=b"{}", headers={"Content-Length": "9999999"}),
    ],
)
async def test_an_unusable_token_answer_is_a_401(
    name: str, response: httpx.Response, http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    endpoints.replace[TOKEN_URL[name]] = response
    await refused(make(name, http), 401, "invalid_provider_token")


@BOTH
async def test_a_chunked_body_is_cut_off_at_the_limit(
    name: str, http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    def endless(request: httpx.Request) -> httpx.Response:
        async def chunks() -> AsyncIterator[bytes]:
            for _ in range(1000):  # 1000 KiB if it were read to the end
                yield b" " * 1024

        return httpx.Response(200, content=chunks())

    endpoints.replace[TOKEN_URL[name]] = endless
    await refused(make(name, http), 401, "invalid_provider_token")


@BOTH
@pytest.mark.parametrize("user", [{}, {"id": ""}, {"id": None}, {"user_id": None}, {"id": 1.5}])
async def test_a_user_without_a_usable_id_is_a_401(
    name: str, user: dict[str, Any], http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    endpoints.yandex_user = dict(user)
    endpoints.replace[VK_USER_INFO_URL] = httpx.Response(200, json={"user": user})
    await refused(make(name, http), 401, "invalid_provider_token")


async def test_vk_user_of_another_id_than_the_token_is_refused(
    http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    endpoints.vk_user = {"user_id": "999"}
    await refused(make("vk_id", http), 401, "invalid_provider_token")


async def test_vk_state_returned_changed_is_refused(
    http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    endpoints.replace[VK_TOKEN_URL] = httpx.Response(
        200, json={"access_token": ACCESS_TOKEN, "state": "another-state", "user_id": VK_SUBJECT}
    )
    await refused(make("vk_id", http), 401, "invalid_provider_token")


async def test_vk_answer_without_the_state_echo_is_refused(
    http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    endpoints.replace[VK_TOKEN_URL] = httpx.Response(
        200, json={"access_token": ACCESS_TOKEN, "user_id": VK_SUBJECT}
    )
    await refused(make("vk_id", http), 401, "invalid_provider_token")


async def test_yandex_answer_without_the_client_id_is_refused(
    http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    endpoints.yandex_user = {"id": YANDEX_SUBJECT}
    await refused(make("yandex_id", http), 401, "invalid_provider_token")


async def test_yandex_asks_for_json_in_the_query(
    http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    await verify(make("yandex_id", http))
    assert endpoints.calls[1].url == f"{YANDEX_INFO_URL}?format=json"


async def test_yandex_token_of_another_app_is_refused(
    http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    endpoints.yandex_user = {"id": YANDEX_SUBJECT, "client_id": "someone-elses-app"}
    await refused(make("yandex_id", http), 401, "invalid_provider_token")


@BOTH
@pytest.mark.parametrize(
    "kwargs",
    [{"nonce": None}, {"verifier": None}, {"platform": "ios"}, {"code": ""}],
    ids=["no-state", "no-verifier", "ios", "empty-code"],
)
async def test_a_missing_binding_is_refused_without_asking_the_provider(
    name: str, kwargs: dict[str, Any], http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    await refused(make(name, http), 401, "invalid_provider_token", **kwargs)
    assert endpoints.calls == []


async def test_vk_needs_the_device_id_of_the_authorization(
    http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    await refused(make("vk_id", http), 401, "invalid_provider_token", device_id=None)
    assert endpoints.calls == []


async def test_yandex_does_not_use_a_device_id(http: httpx.AsyncClient) -> None:
    assert (await verify(make("yandex_id", http), device_id=None)).subject == YANDEX_SUBJECT


@BOTH
async def test_the_client_value_is_only_ever_sent_as_a_code(
    name: str, http: httpx.AsyncClient, endpoints: CodeEndpoints
) -> None:
    # A client that sends an access token as the "assertion" gets it exchanged as a code (the
    # provider refuses it): it is never used as a bearer for the user request.
    endpoints.replace[TOKEN_URL[name]] = httpx.Response(400, json={"error": "invalid_grant"})
    await refused(make(name, http), 401, "invalid_provider_token", code="client-access-token")
    assert all("client-access-token" not in str(c.headers) for c in endpoints.calls)
    assert endpoints.to(INFO_URL[name]) == []


# --- secrets stay out of errors and logs --------------------------------------------------------


@BOTH
async def test_no_code_token_or_verifier_reaches_a_log_or_an_error(
    name: str,
    http: httpx.AsyncClient,
    endpoints: CodeEndpoints,
    caplog: pytest.LogCaptureFixture,
    capsys: pytest.CaptureFixture[str],
) -> None:
    caplog.set_level(logging.DEBUG)
    endpoints.email = "log-check@example.com"
    await verify(make(name, http))
    endpoints.replace[TOKEN_URL[name]] = httpx.Response(
        400, json={"error": "invalid_grant", "error_description": f"bad {CODE} {VERIFIER}"}
    )
    with pytest.raises(AppError) as caught:
        await verify(make(name, http))
    captured = capsys.readouterr()
    seen = captured.out + captured.err + caplog.text + str(caught.value) + caught.value.message
    for secret in (CODE, VERIFIER, ACCESS_TOKEN, REFRESH_TOKEN, VK_SECRET, YANDEX_SECRET, STATE):
        assert secret not in seen
    assert "log-check" not in seen
