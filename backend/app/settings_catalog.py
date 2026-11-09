"""Settings of the catalog integration (Phase 4), a mixin of ``app.config.Settings``."""

from __future__ import annotations

import json
from typing import Annotated, Any

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, NoDecode


class CatalogSettings(BaseSettings):
    # Versions of the contribution checkbox text this server knows (ADR 0014 §2). The app sends
    # the version it displayed; an unknown one is refused, so a consent is never recorded
    # against a text the server cannot name.
    # Env: a JSON list or comma-separated (``1,2``).
    gtin_link_consent_versions: Annotated[list[int], NoDecode] = Field(default_factory=lambda: [1])
    # The hourly aggregate of opted-in links for the catalog (milestone 4.7). Strict
    # environments refuse it until consent records exist (Phase 5): see ``Settings``.
    catalog_contributions_enabled: bool = False

    @field_validator("gtin_link_consent_versions", mode="before")
    @classmethod
    def _split_versions(cls, value: Any) -> Any:
        if isinstance(value, str):
            text = value.strip()
            if text.startswith("["):
                return json.loads(text)
            return [part.strip() for part in text.split(",") if part.strip()]
        return value

    @field_validator("gtin_link_consent_versions")
    @classmethod
    def _versions(cls, value: list[int]) -> list[int]:
        if not value or any(v < 1 for v in value):
            raise ValueError("GTIN_LINK_CONSENT_VERSIONS must be a non-empty list of versions >= 1")
        return value
