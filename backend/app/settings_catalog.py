"""Settings of the catalog integration (Phase 4), a mixin of ``app.config.Settings``."""

from __future__ import annotations

import json
from typing import Annotated, Any, Self
from urllib.parse import urlsplit

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, NoDecode

# Real deployments (``Settings`` and the catalog link rules share this one tuple).
STRICT_ENVIRONMENTS = ("staging", "prod")
MIN_INGEST_TOKEN_LENGTH = 32


class CatalogSettings(BaseSettings):
    # Versions of the contribution checkbox text this server knows (ADR 0014 §2). The app sends
    # the version it displayed; an unknown one is refused, so a consent is never recorded
    # against a text the server cannot name.
    # Env: a JSON list or comma-separated (``1,2``).
    gtin_link_consent_versions: Annotated[list[int], NoDecode] = Field(default_factory=lambda: [1])
    # The hourly aggregate of opted-in links for the catalog (milestone 4.7). Strict
    # environments refuse it until consent records exist (Phase 5): see ``Settings``.
    catalog_contributions_enabled: bool = False
    # The catalog's private listener and this region's ingest secret (catalog/README.md). Only
    # aggregates ``{gtin, product_id, count}`` are ever sent there (ADR 0014 section 3).
    catalog_internal_url: str = ""
    catalog_ingest_token: SecretStr | None = Field(default=None, min_length=MIN_INGEST_TOKEN_LENGTH)
    catalog_contribution_interval_seconds: int = Field(default=3600, ge=60)
    # Owner decision D8: an account counts only after this many days.
    catalog_contribution_min_account_age_days: int = Field(default=7, ge=1)
    # A count below 2 is one person: the floor cannot be configured away (ge=2).
    catalog_contribution_min_reported_count: int = Field(default=2, ge=2)
    catalog_contribution_page_size: int = Field(default=500, ge=1, le=5000)
    catalog_http_timeout_seconds: float = Field(default=15.0, gt=0, le=120)
    # The complete page makes the catalog swap and re-decide a whole snapshot: it may take longer.
    catalog_complete_page_timeout_seconds: float = Field(default=120.0, gt=0, le=600)
    # Send an empty snapshot (counts drop to zero at the catalog) once. This also happens by
    # itself when contributions are disabled while the catalog URL and token are configured.
    catalog_contributions_retract: bool = False
    # The private listener limits requests per token: on a 429 the sender waits for Retry-After
    # (at most this long) and resends the same page, a bounded number of times.
    catalog_rate_limit_retries: int = Field(default=5, ge=0, le=20)
    catalog_rate_limit_max_sleep_seconds: float = Field(default=30, gt=0, le=300)

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

    @field_validator("catalog_ingest_token", mode="before")
    @classmethod
    def _blank_token_is_unset(cls, value: Any) -> Any:
        # Compose passes ``CATALOG_INGEST_TOKEN=`` when the variable is not set in ``.env``.
        return None if isinstance(value, str) and not value.strip() else value

    @field_validator("catalog_internal_url")
    @classmethod
    def _bare_http_origin(cls, value: str) -> str:
        if not value.strip():
            return ""
        parts = urlsplit(value.strip())
        bare = (
            parts.scheme in ("http", "https")
            and parts.hostname is not None
            and "@" not in parts.netloc  # credentials never travel in a URL
            and parts.path in ("", "/")
            and not parts.query
            and not parts.fragment
        )
        if not bare:
            raise ValueError(
                "CATALOG_INTERNAL_URL must be a bare http(s) origin, e.g. https://host"
            )
        return f"{parts.scheme}://{parts.netloc}"

    @model_validator(mode="after")
    def _contribution_transport(self) -> Self:
        # ``environment`` belongs to the class this is mixed into.
        environment = getattr(self, "environment", "dev")
        if (
            environment in STRICT_ENVIRONMENTS
            and self.catalog_internal_url
            and not self.catalog_internal_url.startswith("https://")
        ):
            raise ValueError("CATALOG_INTERNAL_URL must use https when ENVIRONMENT=staging or prod")
        if self.catalog_contributions_enabled:
            if not self.catalog_internal_url:
                raise ValueError(
                    "CATALOG_INTERNAL_URL is required with CATALOG_CONTRIBUTIONS_ENABLED"
                )
            if self.catalog_ingest_token is None:
                raise ValueError(
                    "CATALOG_INGEST_TOKEN is required with CATALOG_CONTRIBUTIONS_ENABLED"
                )
        return self
