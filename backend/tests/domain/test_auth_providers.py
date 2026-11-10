"""The provider matrix (TZ section 1, ADR 0017 section 1) and the passwordless sentinel."""

from __future__ import annotations

import pytest

from app.domain.auth_providers import (
    PLATFORMS,
    PROVIDER_MATRIX,
    PROVIDERS,
    is_allowed,
    providers_for,
    region_providers,
)
from app.domain.passwords import UNUSABLE_PASSWORD_HASH, has_usable_password


@pytest.mark.parametrize(
    ("region", "platform", "expected"),
    [
        ("ru", "android", ["vk_id", "yandex_id"]),
        ("ru", "ios", []),  # RU-iOS is e-mail only
        ("eu", "android", ["google"]),
        ("eu", "ios", ["apple", "google"]),
    ],
)
def test_the_matrix_of_tz_section_1(region: str, platform: str, expected: list[str]) -> None:
    assert providers_for(region, platform) == expected


def test_no_provider_crosses_regions() -> None:
    assert region_providers("ru") == ("vk_id", "yandex_id")
    assert region_providers("eu") == ("apple", "google")
    for provider in PROVIDERS:
        regions = [r for r in PROVIDER_MATRIX if provider in PROVIDER_MATRIX[r]]
        assert len(regions) == 1, provider


@pytest.mark.parametrize(
    ("region", "provider", "platform"),
    [
        ("ru", "apple", "ios"),
        ("ru", "google", "android"),
        ("eu", "vk_id", "android"),
        ("eu", "yandex_id", "android"),
        ("ru", "vk_id", "ios"),
        ("eu", "apple", "android"),
        ("xx", "google", "android"),
        ("ru", "facebook", "android"),
        ("ru", "vk_id", "web"),
    ],
)
def test_everything_else_is_refused(region: str, provider: str, platform: str) -> None:
    assert not is_allowed(region, provider, platform)


def test_every_matrix_entry_uses_known_names() -> None:
    for providers in PROVIDER_MATRIX.values():
        for provider, platforms in providers.items():
            assert provider in PROVIDERS
            assert platforms <= set(PLATFORMS)


def test_the_sentinel_is_not_a_usable_password() -> None:
    assert not has_usable_password(UNUSABLE_PASSWORD_HASH)
    assert has_usable_password("$argon2id$v=19$m=1024,t=1,p=1$c2FsdA$aGFzaA")
    assert not UNUSABLE_PASSWORD_HASH.startswith("$argon2")
