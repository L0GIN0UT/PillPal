"""Remote config settings (milestone 5.12), a mixin of ``app.config.Settings``."""

from __future__ import annotations

from pydantic import Field
from pydantic_settings import BaseSettings

from app.domain.remote_config import AdsConfig


class RemoteConfigSettings(BaseSettings):
    # JSON, e.g. {"placements": {"settings": {"android": "<unit id>"}}}. Empty by default: no ads.
    # Placements are validated against the allowlist of ADR 0018 section 2 at startup.
    remote_config_ads: AdsConfig = Field(default_factory=AdsConfig)
