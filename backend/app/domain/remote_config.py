"""Remote config: the ads allowlist (ADR 0018 sections 2 and 8, milestone 5.12).

Pure, no IO. Ads appear only on named non-medical screens. The app (A2, ``adsAllowedProvider``)
mirrors ``ADS_ALLOWED_SCREENS``: change both together. Any other screen name (reminder, dose,
today, medication, history, relatives, reports, catalog, scan, consent, export, privacy, or an
unknown one) is refused when the settings load, so a typo cannot put an ad next to medical data.
"""

from __future__ import annotations

from typing import Final

from pydantic import BaseModel, ConfigDict, Field, field_validator

ADS_ALLOWED_SCREENS: Final[frozenset[str]] = frozenset({"settings", "about"})
PLATFORMS: Final[tuple[str, ...]] = ("android", "ios")
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
        # The screen name is a fixed identifier, not user data, but it is still not echoed back.
        if any(screen not in ADS_ALLOWED_SCREENS for screen in value):
            raise ValueError("an ads placement is not on the allowlist of screens")
        return value


def placements_for(ads: AdsConfig, platform: str) -> dict[str, str]:
    """Screen -> ad unit id for one platform; screens without an id there are left out."""
    unit_ids = {
        screen: getattr(placement, platform) for screen, placement in ads.placements.items()
    }
    return {screen: unit_id for screen, unit_id in unit_ids.items() if unit_id}
