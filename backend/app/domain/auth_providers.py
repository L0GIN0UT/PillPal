"""Sign-in providers per region and platform (TZ section 1, ADR 0017 section 1). Pure: no IO.

RU-Android has VK ID and Yandex ID, RU-iOS has e-mail only; the rest of the world has Apple (iOS)
and Google (Android, iOS). A provider that is not in the row of the server's region is never
available, whatever is configured.
"""

from __future__ import annotations

from typing import Literal, get_args

Provider = Literal["apple", "google", "vk_id", "yandex_id"]
Platform = Literal["android", "ios"]

PROVIDERS: tuple[str, ...] = get_args(Provider)
PLATFORMS: tuple[str, ...] = get_args(Platform)

# Region -> provider -> platforms. The order of a region's providers is the order offered.
PROVIDER_MATRIX: dict[str, dict[str, frozenset[str]]] = {
    "ru": {"vk_id": frozenset({"android"}), "yandex_id": frozenset({"android"})},
    "eu": {"apple": frozenset({"ios"}), "google": frozenset({"android", "ios"})},
}


def region_providers(region: str) -> tuple[str, ...]:
    return tuple(PROVIDER_MATRIX.get(region, {}))


def is_allowed(region: str, provider: str, platform: str) -> bool:
    return platform in PROVIDER_MATRIX.get(region, {}).get(provider, frozenset())


def providers_for(region: str, platform: str) -> list[str]:
    return [p for p in region_providers(region) if is_allowed(region, p, platform)]
