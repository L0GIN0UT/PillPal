"""Remote config settings (milestone 5.12), a mixin of ``app.config.Settings``."""

from __future__ import annotations

import json
from typing import Annotated

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, NoDecode

from app.domain.remote_config import AdsConfig


class RemoteConfigSettings(BaseSettings):
    # JSON, e.g. {"placements": {"settings": {"android": "<unit id>"}}}. Empty or blank = no ads.
    # Placements are validated against the allowlist of ADR 0018 section 2 at startup. NoDecode:
    # pydantic-settings would otherwise fail on an empty string before our validator runs.
    remote_config_ads: Annotated[AdsConfig, NoDecode] = Field(default_factory=AdsConfig)

    @field_validator("remote_config_ads", mode="before")
    @classmethod
    def _parse_remote_config_ads(cls, value: object) -> object:
        if isinstance(value, str | bytes):
            text = value.decode() if isinstance(value, bytes) else value
            if not text.strip():
                return AdsConfig()
            try:
                return json.loads(text)
            except ValueError:
                # Never echo the value into the startup log.
                raise ValueError("REMOTE_CONFIG_ADS is not valid JSON") from None
        return value
