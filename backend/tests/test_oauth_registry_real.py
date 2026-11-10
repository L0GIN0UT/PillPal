"""The registry with the real Apple and Google verifiers, their settings and the sign-up ticket
that carries a sealed token (milestone 5.8). No database, no Redis."""

from __future__ import annotations

import uuid

import pytest
from pydantic import ValidationError

from app.oauth.apple import AppleProvider
from app.oauth.fake import FakeProvider
from app.oauth.google import GoogleProvider
from app.oauth.registry import ProviderRegistry
from app.services.oauth_state import SignupTicket
from tests.conftest import make_settings
from tests.oauth_real_helpers import (
    APPLE_CLIENT_ID,
    APPLE_SETTINGS,
    GOOGLE_ANDROID_ID,
    GOOGLE_IOS_ID,
)

EU = {"region": "eu", "feature_oauth": True}


def test_configured_providers_get_the_real_verifier() -> None:
    registry = ProviderRegistry(
        make_settings(**EU, oauth_apple_client_id=APPLE_CLIENT_ID, oauth_google_client_id="g")
    )
    assert isinstance(registry.get("apple", "ios"), AppleProvider)
    assert isinstance(registry.get("google", "android"), GoogleProvider)


def test_the_real_verifier_replaces_the_fake_even_when_the_fake_is_on() -> None:
    registry = ProviderRegistry(
        make_settings(**EU, oauth_fake_provider=True, oauth_apple_client_id=APPLE_CLIENT_ID)
    )
    assert isinstance(registry.get("apple", "ios"), AppleProvider)
    # Google has no client id here: the double stands in (dev and test only).
    assert isinstance(registry.get("google", "android"), FakeProvider)


def test_an_unconfigured_provider_is_not_offered_without_the_fake() -> None:
    registry = ProviderRegistry(make_settings(**EU))
    assert registry.get("apple", "ios") is None
    assert registry.get("google", "android") is None
    assert registry.available("ios") == []


def test_google_is_offered_only_on_platforms_with_a_client_id() -> None:
    registry = ProviderRegistry(make_settings(**EU, oauth_google_client_id=GOOGLE_ANDROID_ID))
    assert registry.available("android") == ["google"]
    assert registry.available("ios") == []
    both = ProviderRegistry(
        make_settings(
            **EU,
            oauth_google_client_id=GOOGLE_ANDROID_ID,
            oauth_google_ios_client_id=GOOGLE_IOS_ID,
        )
    )
    assert both.available("ios") == ["google"]


def test_ru_never_gets_apple_or_google() -> None:
    registry = ProviderRegistry(
        make_settings(region="ru", feature_oauth=True, oauth_fake_provider=True)
    )
    assert registry.get("apple", "ios") is None
    assert registry.get("google", "android") is None


async def test_the_http_client_has_the_configured_timeout_and_does_not_follow_redirects() -> None:
    registry = ProviderRegistry(make_settings(**EU, oauth_http_timeout_seconds=7))
    client = registry.http_client()
    assert client.timeout.read == 7
    assert client.follow_redirects is False
    await registry.aclose()


def test_the_token_helper_is_inert_without_apple_settings() -> None:
    assert ProviderRegistry(make_settings(**EU)).tokens is not None


# --- settings ---------------------------------------------------------------------------------


@pytest.mark.parametrize("environment", ["dev", "test", "staging", "prod"])
def test_ru_refuses_the_google_ios_client_id(environment: str) -> None:
    with pytest.raises(ValidationError, match="not allowed when REGION=ru"):
        make_settings(region="ru", environment=environment, oauth_google_ios_client_id="x")


@pytest.mark.parametrize("environment", ["staging", "prod"])
def test_a_strict_apple_needs_the_keyring(environment: str) -> None:
    with pytest.raises(ValidationError, match="DATA_ENCRYPTION_KEYS"):
        make_settings(
            **{**APPLE_SETTINGS, "environment": environment},
            data_encryption_keys={},
            data_encryption_key_id=None,
        )


def test_a_strict_google_alone_does_not_need_the_keyring() -> None:
    settings = make_settings(
        region="eu",
        environment="prod",
        oauth_google_client_id="g",
        data_encryption_keys={},
        data_encryption_key_id=None,
    )
    assert settings.oauth_google_client_id == "g"


@pytest.mark.parametrize("environment", ["staging", "prod"])
def test_a_partial_apple_is_refused_in_strict_environments(environment: str) -> None:
    with pytest.raises(ValidationError, match="partially configured"):
        make_settings(region="eu", environment=environment, oauth_apple_client_id="x")


def test_the_new_knobs_have_sane_bounds() -> None:
    settings = make_settings(region="eu")
    assert settings.oauth_jwks_cache_seconds == 3600
    assert settings.oauth_jwks_refresh_cooldown_seconds == 30
    assert settings.oauth_clock_skew_seconds == 30
    assert settings.oauth_apple_client_secret_ttl_seconds == 86400
    for bad in (
        {"oauth_clock_skew_seconds": 301},
        {"oauth_jwks_cache_seconds": 59},
        {"oauth_apple_client_secret_ttl_seconds": 59},
    ):
        with pytest.raises(ValidationError):
            make_settings(region="eu", **bad)


# --- the ticket -------------------------------------------------------------------------------


def ticket(**extra: object) -> SignupTicket:
    values: dict[str, object] = {
        "provider": "apple",
        "subject": "s",
        "email": None,
        "email_verified": False,
        "region": "eu",
        "platform": "ios",
    }
    values.update(extra)
    return SignupTicket(**values)  # type: ignore[arg-type]


def test_a_ticket_without_a_token_binds_nothing() -> None:
    assert ticket().bound_token() is None
    assert ticket(identity_id=str(uuid.uuid4())).bound_token() is None


def test_a_ticket_returns_the_identity_id_and_the_sealed_token() -> None:
    identity_id = uuid.uuid4()
    bound = ticket(identity_id=str(identity_id), refresh_token_enc="0aff").bound_token()
    assert bound == (identity_id, b"\x0a\xff")


@pytest.mark.parametrize(
    "extra",
    [
        {"identity_id": "not-a-uuid", "refresh_token_enc": "00"},
        {"identity_id": str(uuid.uuid4()), "refresh_token_enc": "zz"},
    ],
)
def test_a_malformed_bound_token_is_ignored(extra: dict[str, str]) -> None:
    assert ticket(**extra).bound_token() is None
