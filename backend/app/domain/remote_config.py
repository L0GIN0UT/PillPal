"""Remote config: the ads allowlist (ADR 0018 sections 2 and 8, milestone 5.12).

Pure, no IO. Ads appear only on named non-medical screens. The app (A2, ``adsAllowedProvider``)
mirrors ``ADS_ALLOWED_SCREENS``: change both together. Any other screen name (reminder, dose,
today, medication, history, relatives, reports, catalog, scan, consent, export, privacy, or an
unknown one) is refused when the settings load, so a typo cannot put an ad next to medical data.
"""

from __future__ import annotations

from typing import Final, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

ADS_ALLOWED_SCREENS: Final[frozenset[str]] = frozenset({"settings", "about"})
Platform = Literal["android", "ios"]
MAX_AD_UNIT_ID_LENGTH = 128


class AdPlacementConfig(BaseModel):
    """One screen: the ad unit id per platform (public identifiers, not secrets)."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    android: str | None = Field(default=None, min_length=1, max_length=MAX_AD_UNIT_ID_LENGTH)
    ios: str | None = Field(default=None, min_length=1, max_length=MAX_AD_UNIT_ID_LENGTH)


class AdsConfig(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    placements: dict[str, AdPlacementConfig] = Field(default_factory=dict)

    @field_validator("placements")
    @classmethod
    def _only_allowlisted_screens(
        cls, value: dict[str, AdPlacementConfig]
    ) -> dict[str, AdPlacementConfig]:
        # The offending screen name is deliberately left out of the message.
        if any(screen not in ADS_ALLOWED_SCREENS for screen in value):
            raise ValueError("an ads placement is not on the allowlist of screens")
        return value


def placements_for(ads: AdsConfig, platform: Platform) -> dict[str, str]:
    """Screen -> ad unit id for one platform, sorted; screens without an id are omitted."""
    result: dict[str, str] = {}
    for screen in sorted(ads.placements):
        placement = ads.placements[screen]
        unit_id = placement.android if platform == "android" else placement.ios
        if unit_id:
            result[screen] = unit_id
    return result
