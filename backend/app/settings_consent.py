"""Settings of consent records (Phase 5.2a), a mixin of ``app.config.Settings``."""

from __future__ import annotations

import itertools
import json
from typing import Annotated, Any

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, NoDecode

from app.domain.consents import MAX_CONSENT_VERSION


def _split(value: Any) -> Any:
    # Env: a JSON list or comma-separated (``1,2``), as for GTIN_LINK_CONSENT_VERSIONS.
    if isinstance(value, str):
        text = value.strip()
        if text.startswith("["):
            return json.loads(text)
        return [part.strip() for part in text.split(",") if part.strip()]
    return value


class ConsentSettings(BaseSettings):
    # Versions of each consent text this server knows; the highest is the current one. The app
    # sends the version it displayed, and an unknown one is refused, so a consent is never
    # recorded against a text the server cannot name. The catalog contribution reuses
    # ``GTIN_LINK_CONSENT_VERSIONS``.
    consent_versions_health_data: Annotated[list[int], NoDecode] = Field(
        default_factory=lambda: [1]
    )
    consent_versions_terms: Annotated[list[int], NoDecode] = Field(default_factory=lambda: [1])
    consent_versions_privacy: Annotated[list[int], NoDecode] = Field(default_factory=lambda: [1])
    # Registration must carry the current health data, terms and privacy consents. Off until
    # the app sends them (milestone 5.11); a request that does carry them is validated anyway.
    # ENVIRONMENT=prod: true when unset, and explicitly false is refused (``Settings``).
    consent_required_at_registration: bool = False

    @field_validator(
        "consent_versions_health_data",
        "consent_versions_terms",
        "consent_versions_privacy",
        mode="before",
    )
    @classmethod
    def _split_consent_versions(cls, value: Any) -> Any:
        return _split(value)

    @field_validator(
        "consent_versions_health_data", "consent_versions_terms", "consent_versions_privacy"
    )
    @classmethod
    def _consent_versions(cls, value: list[int]) -> list[int]:
        if (
            not value
            or any(a >= b for a, b in itertools.pairwise(value))
            or any(not 1 <= v <= MAX_CONSENT_VERSION for v in value)
        ):
            raise ValueError(
                "CONSENT_VERSIONS_* must be a non-empty, strictly increasing list of versions "
                f"1..{MAX_CONSENT_VERSION}"
            )
        return value
