"""The Apple and Google ID-token verifiers (ADR 0017 section 3), through ``httpx.MockTransport``
with keys generated in the test. No database, no Redis."""

from __future__ import annotations

import hashlib
from collections.abc import Callable
from datetime import timedelta
from typing import Any

import httpx
import pytest

from app.errors import AppError
from app.oauth.apple import AppleProvider
from app.oauth.base import IdentityProvider, VerifiedIdentity
from app.oauth.google import GoogleProvider
from app.oauth.jwks import JwksCache
from tests.conftest import make_settings
from tests.oauth_real_helpers import (
    APPLE_CLIENT_ID,
    APPLE_ISSUER,
    EC_KEY,
    GOOGLE_ANDROID_ID,
    GOOGLE_IOS_ID,
    GOOGLE_ISSUER,
    NONCE,
    NOW,
    OTHER_RSA_KEY,
    JwksServer,
    claims,
    hs256_with_public_key,
    sign,
    timeout,
    unsigned,
)

SETTINGS = make_settings(
    region="eu",
    oauth_apple_client_id=APPLE_CLIENT_ID,
    oauth_google_client_id=GOOGLE_ANDROID_ID,
    oauth_google_ios_client_id=GOOGLE_IOS_ID,
)


def jwks(server: JwksServer) -> JwksCache:
    http = httpx.AsyncClient(transport=httpx.MockTransport(server.handler))
    return JwksCache(
        "https://keys.example/jwks", http, ttl_seconds=3600, refresh_cooldown_seconds=30
    )


class Case:
    """One provider under test: how to build a verifier and a valid claim set for it."""

    def __init__(
        self,
        name: str,
        platform: str,
        issuer: str,
        audience: str,
        make: Callable[[JwksCache], IdentityProvider],
    ) -> None:
        self.name = name
        self.platform = platform
        self.issuer = issuer
        self.audience = audience
        self.make = make

    def claims(self, **extra: Any) -> dict[str, Any]:
        return claims(issuer=self.issuer, audience=self.audience, **extra)


def _apple(cache: JwksCache) -> IdentityProvider:
    return AppleProvider(SETTINGS, cache)


def _google(cache: JwksCache) -> IdentityProvider:
    return GoogleProvider(SETTINGS, cache)


CASES = {
    "apple": Case("apple", "ios", APPLE_ISSUER, APPLE_CLIENT_ID, _apple),
    "google-android": Case("google", "android", GOOGLE_ISSUER, GOOGLE_ANDROID_ID, _google),
    "google-ios": Case("google", "ios", "accounts.google.com", GOOGLE_IOS_ID, _google),
}


@pytest.fixture(params=sorted(CASES))
def case(request: pytest.FixtureRequest) -> Case:
    return CASES[request.param]


async def verify(
    case: Case,
    token: str,
    *,
    server: JwksServer | None = None,
    nonce: str | None = NONCE,
    platform: str | None = None,
) -> VerifiedIdentity:
    provider = case.make(jwks(server or JwksServer()))
    return await provider.verify(
        token, nonce=nonce, platform=platform or case.platform, code_verifier=None, now=NOW
    )


async def refused(case: Case, token: str, code: str = "invalid_provider_token", **kw: Any) -> None:
    with pytest.raises(AppError) as info:
        await verify(case, token, **kw)
    assert info.value.code == code


# --- a good token -----------------------------------------------------------------------------


async def test_a_good_token_is_verified(case: Case) -> None:
    token = sign(case.claims())
    identity = await verify(case, token)
    assert identity.provider == case.name
    assert identity.subject == "provider-subject-1"
    assert identity.email == "person@example.com"
    assert identity.email_verified is True
    assert identity.issued_at == NOW  # the iat: re-authentication freshness reads it
    assert identity.expires_at == NOW + timedelta(hours=1)
    assert identity.assertion_id == hashlib.sha256(token.encode()).hexdigest()


async def test_an_es256_token_is_accepted(case: Case) -> None:
    server = JwksServer({"k1": EC_KEY})
    token = sign(case.claims(), key=EC_KEY, alg="ES256")
    assert (await verify(case, token, server=server)).subject


async def test_the_issuer_may_be_either_google_form() -> None:
    for issuer in ("accounts.google.com", "https://accounts.google.com"):
        case = Case("google", "android", issuer, GOOGLE_ANDROID_ID, _google)
        assert (await verify(case, sign(case.claims()))).provider == "google"


async def test_a_string_email_verified_counts_and_a_missing_one_does_not(case: Case) -> None:
    assert (await verify(case, sign(case.claims(email_verified="true")))).email_verified is True
    for value in ("false", False, None):
        token = sign(case.claims(email_verified=value))
        assert (await verify(case, token)).email_verified is False


async def test_a_token_without_an_email_has_none(case: Case) -> None:
    identity = await verify(case, sign(case.claims(email=None, email_verified=None)))
    assert identity.email is None
    assert identity.email_verified is False


# --- refusals ---------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "override",
    [
        {"iss": "https://evil.example"},
        {"iss": "https://accounts.google.com.evil.example"},
        {"aud": "someone-else"},
        {"aud": ["someone-else"]},
        {"aud": None},
        {"iss": None},
        {"sub": None},
        {"sub": ""},
        {"sub": "x" * 256},
        {"sub": 12},
        {"exp": None},
        {"iat": None},
        {"exp": "soon"},
        {"nonce": "not-the-digest"},
    ],
)
async def test_wrong_claims_are_refused(case: Case, override: dict[str, Any]) -> None:
    body = case.claims()
    body.update(override)
    await refused(case, sign({k: v for k, v in body.items() if v is not None}))


async def test_the_nonce_must_be_the_digest_of_the_server_nonce(case: Case) -> None:
    await refused(case, sign(case.claims(nonce="another-server-nonce-" + "x" * 20)))
    await refused(case, sign(case.claims(nonce=None)))  # no nonce claim at all
    await refused(case, sign(case.claims()), nonce=None)  # the server has none to compare


async def test_the_raw_nonce_in_the_token_is_not_accepted(case: Case) -> None:
    body = case.claims()
    body["nonce"] = NONCE  # the client must send the sha256, never the raw nonce
    await refused(case, sign(body))


async def test_an_expired_token_is_refused(case: Case) -> None:
    await refused(case, sign(case.claims(exp=int((NOW - timedelta(seconds=1)).timestamp()))))
    await refused(case, sign(case.claims(exp=int(NOW.timestamp()))))


async def test_a_token_from_the_future_is_refused_beyond_the_skew(case: Case) -> None:
    skew = SETTINGS.oauth_clock_skew_seconds
    ok = int((NOW + timedelta(seconds=skew)).timestamp())
    too_late = int((NOW + timedelta(seconds=skew + 1)).timestamp())
    assert (await verify(case, sign(case.claims(iat=ok)))).subject
    await refused(case, sign(case.claims(iat=too_late)))


async def test_a_stale_iat_is_reported_so_reauth_can_refuse_it(case: Case) -> None:
    old = NOW - timedelta(minutes=30)
    identity = await verify(case, sign(case.claims(iat=int(old.timestamp()))))
    assert identity.issued_at == old


@pytest.mark.parametrize("make", [unsigned, hs256_with_public_key])
async def test_alg_none_and_hs256_are_refused(case: Case, make: Callable[..., str]) -> None:
    await refused(case, make(case.claims()))


async def test_a_token_signed_by_another_key_is_refused(case: Case) -> None:
    await refused(case, sign(case.claims(), key=OTHER_RSA_KEY))


async def test_an_alg_that_does_not_match_the_key_is_refused(case: Case) -> None:
    # An EC-signed token whose kid names the RSA key must not verify.
    await refused(case, sign(case.claims(), key=EC_KEY, alg="ES256"))


@pytest.mark.parametrize("token", ["", "abc", "a.b.c", "a.b", "....", "\u0000"])
async def test_garbage_is_refused(case: Case, token: str) -> None:
    await refused(case, token)


async def test_a_token_without_a_kid_is_refused(case: Case) -> None:
    await refused(case, sign(case.claims(), kid=None))


async def test_an_unknown_kid_refetches_once_then_refuses(case: Case) -> None:
    server = JwksServer()
    provider = case.make(jwks(server))
    await provider.verify(
        sign(case.claims()), nonce=NONCE, platform=case.platform, code_verifier=None, now=NOW
    )
    with pytest.raises(AppError) as info:
        await provider.verify(
            sign(case.claims(), kid="rotated"),
            nonce=NONCE,
            platform=case.platform,
            code_verifier=None,
            now=NOW + timedelta(minutes=1),
        )
    assert info.value.code == "invalid_provider_token"
    assert server.requests == 2


async def test_a_rotated_key_is_picked_up(case: Case) -> None:
    server = JwksServer()
    provider = case.make(jwks(server))
    await provider.verify(
        sign(case.claims()), nonce=NONCE, platform=case.platform, code_verifier=None, now=NOW
    )
    server.keys["k2"] = OTHER_RSA_KEY
    identity = await provider.verify(
        sign(case.claims(), key=OTHER_RSA_KEY, kid="k2"),
        nonce=NONCE,
        platform=case.platform,
        code_verifier=None,
        now=NOW + timedelta(minutes=1),
    )
    assert identity.subject == "provider-subject-1"


async def test_a_provider_timeout_is_provider_unreachable(case: Case) -> None:
    server = JwksServer()
    server.fail = timeout
    await refused(case, sign(case.claims()), code="provider_unreachable", server=server)


# --- audience per platform --------------------------------------------------------------------


async def test_apple_is_ios_only_and_the_audience_is_its_client_id() -> None:
    apple = CASES["apple"]
    await refused(apple, sign(apple.claims()), platform="android")


async def test_google_takes_the_audience_of_the_claimed_platform_only() -> None:
    android, ios = CASES["google-android"], CASES["google-ios"]
    # An iOS audience claimed as Android (or the reverse) cannot pick the other verifier.
    await refused(android, sign(ios.claims()), platform="android")
    await refused(ios, sign(android.claims()), platform="ios")


async def test_google_without_an_ios_client_id_refuses_ios() -> None:
    settings = make_settings(region="eu", oauth_google_client_id=GOOGLE_ANDROID_ID)
    provider = GoogleProvider(settings, jwks(JwksServer()))
    ios = CASES["google-ios"]
    with pytest.raises(AppError) as info:
        await provider.verify(
            sign(ios.claims()), nonce=NONCE, platform="ios", code_verifier=None, now=NOW
        )
    assert info.value.code == "invalid_provider_token"


async def test_google_azp_must_be_our_client_id_when_present() -> None:
    google = CASES["google-android"]
    assert (await verify(google, sign(google.claims(azp=GOOGLE_ANDROID_ID)))).subject
    await refused(google, sign(google.claims(azp="another-client")))
    await refused(google, sign(google.claims(azp=GOOGLE_IOS_ID)))  # our other platform's id


async def test_several_audiences_need_a_matching_azp() -> None:
    google = CASES["google-android"]
    body = google.claims(aud=[GOOGLE_ANDROID_ID, "other"])
    await refused(google, sign(body))
    assert (await verify(google, sign({**body, "azp": GOOGLE_ANDROID_ID}))).subject


async def test_the_token_never_appears_in_an_error(case: Case) -> None:
    token = sign(case.claims(aud="someone-else"))
    with pytest.raises(AppError) as info:
        await verify(case, token)
    assert token not in info.value.message
