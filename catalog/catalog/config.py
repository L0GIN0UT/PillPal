"""Catalog settings, loaded from environment variables.

The catalog is a global service without personal data (ADR 0011). Its variables are
``CATALOG_*`` so they never collide with the regional backend's when both run on one host;
``ENVIRONMENT`` and ``LOG_LEVEL`` are shared names on purpose.
"""

from __future__ import annotations

import re
import secrets
from typing import Annotated, Literal, Self

from pydantic import (
    AliasChoices,
    BaseModel,
    ConfigDict,
    Field,
    SecretStr,
    ValidationInfo,
    field_validator,
    model_validator,
)
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict

Environment = Literal["dev", "test", "staging", "prod"]
# Real deployments must have service tokens configured.
STRICT_ENVIRONMENTS = ("staging", "prod")

_TOKEN_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
_SHA256_HEX_RE = re.compile(r"^[0-9a-f]{64}$")
# An ingest token speaks for the region its name starts with (``ru``, ``eu``, rotation ``ru-next``).
_INGEST_NAME_RE = re.compile(r"^(ru|eu)(?:[-_].*)?$")
REGIONS = ("ru", "eu")
# The secret behind a digest must be random and long; the digest is all the catalog ever sees.
MIN_TOKEN_SECRET_LENGTH = 32
RATE_LIMIT_SALT_BYTES = 32


class TokenEntry(BaseModel):
    """A service token: a label for the audit trail and the SHA-256 of the secret."""

    model_config = ConfigDict(frozen=True)

    name: str
    sha256: str


def parse_token_list(setting: str, raw: str) -> tuple[TokenEntry, ...]:
    """Parse ``name:sha256hex,name2:sha256hex``. Errors never echo the offending value."""
    entries: list[TokenEntry] = []
    for item in (part.strip() for part in raw.split(",")):
        if not item:
            continue
        name, _, digest = item.partition(":")
        digest = digest.lower()
        if not _TOKEN_NAME_RE.match(name) or not _SHA256_HEX_RE.match(digest):
            raise ValueError(
                f"{setting} entries must look like name:sha256hex (name [a-z0-9_-]{{1,32}}; "
                f"sha256 of a random secret of at least {MIN_TOKEN_SECRET_LENGTH} characters, "
                "never the secret itself)"
            )
        entries.append(TokenEntry(name=name, sha256=digest))
    if len({e.name for e in entries}) != len(entries):
        raise ValueError(f"{setting} contains a duplicate name")
    return tuple(entries)


def normalize_database_url(url: str) -> str:
    """Force the asyncpg driver for plain ``postgres://`` / ``postgresql://`` URLs."""
    for prefix in ("postgresql+asyncpg://", "postgresql://", "postgres://"):
        if url.startswith(prefix):
            return "postgresql+asyncpg://" + url[len(prefix) :]
    return url


def _env(name: str) -> AliasChoices:
    # Settings are filled from the environment by alias and, in tests, by field name.
    return AliasChoices(name, name.lower())


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        extra="ignore",
        case_sensitive=False,
        populate_by_name=True,
        # A pasted secret must not come back in a startup error.
        hide_input_in_errors=True,
    )

    database_url: str = Field(validation_alias=_env("CATALOG_DATABASE_URL"))
    redis_url: str = Field(
        default="redis://localhost:6379/0", validation_alias=_env("CATALOG_REDIS_URL")
    )
    environment: Environment = Field(default="dev", validation_alias=_env("ENVIRONMENT"))
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = Field(
        default="INFO", validation_alias=_env("LOG_LEVEL")
    )
    db_pool_size: int = Field(default=5, ge=1, validation_alias=_env("CATALOG_DB_POOL_SIZE"))

    # Digests of the secrets of the private listener: admin (``name``) and ingest (``ru``, ``eu``,
    # optionally ``ru-next`` for rotation: the region is the part before the first ``-`` or ``_``).
    admin_tokens: Annotated[tuple[TokenEntry, ...], NoDecode] = Field(
        default=(), validation_alias=_env("CATALOG_ADMIN_TOKENS")
    )
    ingest_tokens: Annotated[tuple[TokenEntry, ...], NoDecode] = Field(
        default=(), validation_alias=_env("CATALOG_INGEST_TOKENS")
    )

    # Fixed-window limits (fail-open); the IP bucket is wider because a NAT shares one address.
    rate_limit_window_seconds: int = Field(
        default=60, ge=1, validation_alias=_env("CATALOG_RATE_LIMIT_WINDOW_SECONDS")
    )
    rate_limit_ip_max: int = Field(
        default=240, ge=1, validation_alias=_env("CATALOG_RATE_LIMIT_IP_MAX")
    )
    rate_limit_install_max: int = Field(
        default=60, ge=1, validation_alias=_env("CATALOG_RATE_LIMIT_INSTALL_MAX")
    )
    # After a Redis failure the limiter skips Redis (fail-open) for this long, and logs once.
    rate_limit_unavailable_seconds: int = Field(
        default=30, ge=1, validation_alias=_env("CATALOG_RATE_LIMIT_UNAVAILABLE_SECONDS")
    )
    # HMAC key of the bucket names. Required in staging/prod; elsewhere a random value per process.
    rate_limit_salt: SecretStr | None = Field(
        default=None, validation_alias=_env("CATALOG_RATE_LIMIT_SALT"), min_length=16
    )

    # Public read API (search, lookup, cards). A statement that runs longer is cancelled by
    # PostgreSQL and answered with 503 ``catalog_timeout``.
    search_statement_timeout_ms: int = Field(
        default=300, ge=1, validation_alias=_env("CATALOG_SEARCH_STATEMENT_TIMEOUT_MS")
    )
    # ``word_similarity`` threshold of the typo path; lower finds more typos and more noise.
    search_trigram_threshold: float = Field(
        default=0.5, gt=0, le=1, validation_alias=_env("CATALOG_SEARCH_TRIGRAM_THRESHOLD")
    )
    search_max_limit: int = Field(
        default=20, ge=1, validation_alias=_env("CATALOG_SEARCH_MAX_LIMIT")
    )
    # Matching entries considered per entity kind before ranking (own market first).
    search_entry_cap: int = Field(
        default=200, ge=1, validation_alias=_env("CATALOG_SEARCH_ENTRY_CAP")
    )
    search_substance_cap: int = Field(
        default=25, ge=1, validation_alias=_env("CATALOG_SEARCH_SUBSTANCE_CAP")
    )
    # Request bodies of the public API are tiny JSON objects (ADR 0011 section 6).
    request_body_max_bytes: int = Field(
        default=4096, ge=256, validation_alias=_env("CATALOG_REQUEST_BODY_MAX_BYTES")
    )

    # ESKLP has no published license text and GRLS may only be imported from a manual export:
    # both importers refuse to run until the owner flips the flag (owner decision D1).
    importer_esklp_enabled: bool = Field(
        default=False, validation_alias=_env("CATALOG_IMPORTER_ESKLP_ENABLED")
    )
    importer_grls_enabled: bool = Field(
        default=False, validation_alias=_env("CATALOG_IMPORTER_GRLS_ENABLED")
    )

    # A run that was killed leaves a ``running`` row; after this long it is taken over.
    importer_stale_run_minutes: int = Field(
        default=360, ge=1, validation_alias=_env("CATALOG_IMPORTER_STALE_RUN_MINUTES")
    )

    # Consensus (ADR 0014 section 4, owner decision D8): N matching confirmations promote a link,
    # a runner-up with the dispute minimum parks the number for an admin.
    consensus_min_confirmations: int = Field(
        default=3, ge=1, validation_alias=_env("CATALOG_CONSENSUS_MIN_CONFIRMATIONS")
    )
    consensus_dispute_min: int = Field(
        default=2, ge=1, validation_alias=_env("CATALOG_CONSENSUS_DISPUTE_MIN")
    )
    # Caps of the ingest endpoint on the private listener: items per page, items per snapshot
    # (413 beyond), body bytes (a page of 1000 items is well under 200 KiB).
    ingest_page_max_items: int = Field(
        default=1000, ge=1, validation_alias=_env("CATALOG_INGEST_PAGE_MAX_ITEMS")
    )
    ingest_max_items: int = Field(
        default=200_000, ge=1, validation_alias=_env("CATALOG_INGEST_MAX_ITEMS")
    )
    ingest_body_max_bytes: int = Field(
        default=262_144, ge=1024, validation_alias=_env("CATALOG_INGEST_BODY_MAX_BYTES")
    )
    # Regions whose backends may report here (``ru,eu``). Empty = the ingest endpoint accepts
    # nothing. The default deployment is one catalog per region, so it names only its own region;
    # a single global catalog names every region that reports to it.
    accepted_regions: Annotated[tuple[str, ...], NoDecode] = Field(
        default=(), validation_alias=_env("CATALOG_ACCEPTED_REGIONS")
    )
    # A region whose last committed snapshot is older than this stops counting and its rows are
    # deleted by the maintenance job: a switched-off or abandoned region fades out (retention).
    ingest_max_age_hours: int = Field(
        default=72, ge=1, validation_alias=_env("CATALOG_INGEST_MAX_AGE_HOURS")
    )
    # A generation further ahead of the clock than this is refused (it would block the region).
    ingest_max_generation_skew_seconds: int = Field(
        default=86_400, ge=0, validation_alias=_env("CATALOG_INGEST_MAX_GENERATION_SKEW_SECONDS")
    )
    # How often the private app expires stale regions and re-decides after imports.
    maintenance_interval_seconds: int = Field(
        default=3600, ge=60, validation_alias=_env("CATALOG_MAINTENANCE_INTERVAL_SECONDS")
    )
    # The private listener: a low per-IP limit counts only failed authentication; a valid token is
    # limited per token (a snapshot of 30k items is 30 pages and more, sent in a burst).
    private_rate_limit_ip_max: int = Field(
        default=60, ge=1, validation_alias=_env("CATALOG_PRIVATE_RATE_LIMIT_IP_MAX")
    )
    private_rate_limit_token_max: int = Field(
        default=1000, ge=1, validation_alias=_env("CATALOG_PRIVATE_RATE_LIMIT_TOKEN_MAX")
    )
    # admin_audit rows older than this are purged by the maintenance job (owner default: 2 years).
    audit_retention_days: int = Field(
        default=730, ge=1, validation_alias=_env("CATALOG_AUDIT_RETENTION_DAYS")
    )
    # Page size of ``GET /admin/v1/disputes`` and the import-run list.
    admin_page_max: int = Field(default=100, ge=1, validation_alias=_env("CATALOG_ADMIN_PAGE_MAX"))

    @field_validator("admin_tokens", "ingest_tokens", mode="before")
    @classmethod
    def _parse_tokens(cls, value: object, info: ValidationInfo) -> object:
        if isinstance(value, str):
            setting = f"CATALOG_{(info.field_name or '').removesuffix('_tokens').upper()}_TOKENS"
            return parse_token_list(setting, value)
        return value

    @field_validator("accepted_regions", mode="before")
    @classmethod
    def _parse_regions(cls, value: object) -> object:
        if isinstance(value, str):
            return tuple(part.strip().lower() for part in value.split(",") if part.strip())
        return value

    @field_validator("accepted_regions")
    @classmethod
    def _known_regions(cls, value: tuple[str, ...]) -> tuple[str, ...]:
        if not set(value) <= set(REGIONS):
            raise ValueError("CATALOG_ACCEPTED_REGIONS may name ru and eu only")
        return value

    @field_validator("rate_limit_salt", mode="before")
    @classmethod
    def _blank_salt_is_unset(cls, value: object) -> object:
        # Compose passes ``CATALOG_RATE_LIMIT_SALT=`` when the variable is not set.
        return None if isinstance(value, str) and not value.strip() else value

    @field_validator("database_url")
    @classmethod
    def _normalize_db_url(cls, value: str) -> str:
        return normalize_database_url(value)

    @model_validator(mode="after")
    def _strict_environments(self) -> Self:
        if self.environment in STRICT_ENVIRONMENTS:
            if not self.admin_tokens:
                raise ValueError(
                    "CATALOG_ADMIN_TOKENS is required when ENVIRONMENT=staging or prod"
                )
            if not self.ingest_tokens:
                raise ValueError(
                    "CATALOG_INGEST_TOKENS is required when ENVIRONMENT=staging or prod"
                )
        return self

    @model_validator(mode="after")
    def _ingest_tokens_speak_for_accepted_regions(self) -> Self:
        for entry in self.ingest_tokens:
            found = _INGEST_NAME_RE.match(entry.name)
            if found is None:
                raise ValueError("CATALOG_INGEST_TOKENS names must start with ru or eu")
            if found.group(1) not in self.accepted_regions:
                raise ValueError(
                    "an ingest token names a region missing from CATALOG_ACCEPTED_REGIONS"
                )
        return self

    @model_validator(mode="after")
    def _rate_limit_salt(self) -> Self:
        if self.rate_limit_salt is not None:
            return self
        if self.environment in STRICT_ENVIRONMENTS:
            # A per-process random salt would split the buckets of several processes.
            raise ValueError("CATALOG_RATE_LIMIT_SALT is required when ENVIRONMENT=staging or prod")
        self.rate_limit_salt = SecretStr(secrets.token_hex(RATE_LIMIT_SALT_BYTES))
        return self

    @model_validator(mode="after")
    def _roles_do_not_share_a_token(self) -> Self:
        shared = {t.sha256 for t in self.admin_tokens} & {t.sha256 for t in self.ingest_tokens}
        if shared:
            raise ValueError("a token cannot be both an admin and an ingest token")
        return self
