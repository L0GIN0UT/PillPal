"""VK ID and Yandex ID in the registry and the settings (milestone 5.9): per-region configuration,
secrets from files, and the freshness a re-authentication demands of an exchanged code. Pure."""

from __future__ import annotations

from datetime import timedelta
from pathlib import Path
from typing import Any

import httpx
import pytest
from pydantic import ValidationError

from app.oauth.fake import FakeProvider
from app.oauth.registry import ProviderRegistry
from app.oauth.vk_id import VkIdProvider
from app.oauth.yandex_id import YandexIdProvider
from app.services.reauth import Reauthenticator
from tests.conftest import make_settings
from tests.oauth_code_flow_helpers import exchange
from tests.oauth_code_helpers import (
    BOTH_SETTINGS,
    NOW,
    VK_SECRET,
    VK_SETTINGS,
    YANDEX_SETTINGS,
    CodeEndpoints,
    settings_for,
)

STRICT: dict[str, Any] = {
    "environment": "staging",
    "feature_oauth": True,
    "email_backend": "smtp",
    "smtp_host": "smtp.example.com",
    "smtp_from": "noreply@example.com",
}


def registry(**overrides: Any) -> ProviderRegistry:
    transport = CodeEndpoints().transport()
    return ProviderRegistry(settings_for(**overrides), transport=transport)


# --- which verifier is offered ------------------------------------------------------------------


async def test_a_configured_provider_gets_the_real_verifier_even_with_the_fake_on() -> None:
    reg = registry(oauth_fake_provider=True)
    assert isinstance(reg.get("vk_id", "android"), VkIdProvider)
    assert isinstance(reg.get("yandex_id", "android"), YandexIdProvider)
    assert reg.available("android") == ["vk_id", "yandex_id"]
    await reg.aclose()


async def test_an_unconfigured_provider_is_not_offered_and_the_fake_stands_in_for_it() -> None:
    only_vk = ProviderRegistry(make_settings(**{**VK_SETTINGS, "feature_oauth": True}))
    assert only_vk.available("android") == ["vk_id"]
    with_fake = ProviderRegistry(
        make_settings(**{**VK_SETTINGS, "feature_oauth": True, "oauth_fake_provider": True})
    )
    assert isinstance(with_fake.get("yandex_id", "android"), FakeProvider)
    await only_vk.aclose()
    await with_fake.aclose()


async def test_the_platform_matrix_still_decides() -> None:
    reg = registry()
    assert reg.get("vk_id", "ios") is None
    assert reg.available("ios") == []
    await reg.aclose()


async def test_the_flag_off_offers_nothing_but_reauth_still_finds_the_verifier() -> None:
    reg = registry(feature_oauth=False)
    assert reg.get("vk_id", "android") is None
    assert isinstance(reg.get("vk_id", "android", for_reauth=True), VkIdProvider)
    await reg.aclose()


async def test_the_verifiers_share_the_registry_client() -> None:
    reg = registry()
    vk = reg.get("vk_id", "android")
    assert vk is reg.get("vk_id", "android")  # built once
    await reg.aclose()


# --- settings -----------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "setting",
    [
        {"oauth_vk_client_id": "1"},
        {"oauth_vk_client_secret": "s"},
        {"oauth_vk_redirect_uri": "vk1://vk.ru/blank.html"},
        {"oauth_yandex_client_id": "1"},
        {"oauth_yandex_client_secret": "s"},
    ],
)
@pytest.mark.parametrize("environment", ["dev", "test", "staging"])
def test_eu_refuses_vk_and_yandex_settings_in_every_environment(
    setting: dict[str, Any], environment: str
) -> None:
    extra = STRICT if environment == "staging" else {"environment": environment}
    with pytest.raises(ValidationError, match="not allowed when REGION=eu"):
        make_settings(region="eu", **{**extra, **setting})


def test_ru_accepts_them() -> None:
    settings = make_settings(**BOTH_SETTINGS)
    assert settings.oauth_vk_client_id
    assert settings.oauth_yandex_client_id


@pytest.mark.parametrize(
    "setting",
    [
        {"oauth_vk_client_id": "1"},
        {"oauth_vk_client_secret": "s"},
        {"oauth_vk_redirect_uri": "vk1://vk.ru/blank.html"},
        {"oauth_yandex_client_id": "1"},
        {"oauth_yandex_client_secret": "s"},
    ],
)
def test_a_strict_environment_refuses_a_partial_provider(setting: dict[str, Any]) -> None:
    with pytest.raises(ValidationError, match="partially configured"):
        make_settings(region="ru", **{**STRICT, **setting})


def test_a_strict_environment_accepts_a_complete_provider() -> None:
    make_settings(**{**STRICT, **VK_SETTINGS, **YANDEX_SETTINGS})


@pytest.mark.parametrize("uri", ["not a uri", "vk123", "://missing-scheme", "x" * 600])
def test_a_redirect_uri_must_be_absolute(uri: str) -> None:
    with pytest.raises(ValidationError):
        make_settings(**VK_SETTINGS, oauth_vk_redirect_uri=uri)


@pytest.mark.parametrize("provider", ["vk", "yandex"])
async def test_a_client_secret_can_come_from_a_file(provider: str, tmp_path: Path) -> None:
    secret_file = tmp_path / "secret"
    secret_file.write_text("  secret-from-a-file\n", encoding="utf-8")
    base = {"region": "ru", "feature_oauth": True, f"oauth_{provider}_client_id": "client-1"}
    settings = make_settings(**base, **{f"oauth_{provider}_client_secret_file": str(secret_file)})
    secret = getattr(settings, f"oauth_{provider}_client_secret")
    assert secret is not None
    assert secret.get_secret_value() == "secret-from-a-file"
    reg = ProviderRegistry(settings)
    assert reg.available("android") == [f"{provider}_id"]
    await reg.aclose()


@pytest.mark.parametrize("provider", ["vk", "yandex"])
def test_a_secret_and_its_file_together_are_refused(provider: str, tmp_path: Path) -> None:
    secret_file = tmp_path / "secret"
    secret_file.write_text("x", encoding="utf-8")
    with pytest.raises(ValidationError, match="both set"):
        make_settings(
            region="ru",
            **{
                f"oauth_{provider}_client_id": "c",
                f"oauth_{provider}_client_secret": "s",
                f"oauth_{provider}_client_secret_file": str(secret_file),
            },
        )


def test_the_secret_does_not_show_in_the_settings_repr() -> None:
    assert VK_SECRET not in repr(make_settings(**VK_SETTINGS))


# --- re-auth freshness (5.7): the code is exchanged now, so it is fresh ---------------------------


@pytest.mark.parametrize("name", ["vk_id", "yandex_id"])
async def test_reauth_accepts_an_exchanged_code_only_inside_the_window(name: str) -> None:
    settings = settings_for()
    identity = await exchange(name, settings)
    check = Reauthenticator(None, settings, None, None, None)  # type: ignore[arg-type]
    window = timedelta(seconds=settings.oauth_reauth_max_age_seconds)
    assert check._is_fresh(identity.issued_at, NOW)
    assert check._is_fresh(identity.issued_at, NOW + window)
    assert not check._is_fresh(identity.issued_at, NOW + window + timedelta(seconds=1))


async def test_the_http_client_has_no_redirects_and_the_configured_timeout() -> None:
    reg = registry(oauth_http_timeout_seconds=7)
    client: httpx.AsyncClient = reg.http_client()
    assert client.follow_redirects is False
    assert client.timeout.read == 7
    await reg.aclose()
