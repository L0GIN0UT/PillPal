"""Application settings, loaded from environment variables.

One codebase is deployed per data region (TZ §1): ``REGION`` is mandatory and
every stand only ever serves accounts of its own region.
"""

from __future__ import annotations

import re
from typing import Literal, Self
from urllib.parse import urlsplit

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

Region = Literal["ru", "eu"]
Environment = Literal["dev", "test", "prod"]

# Android signing certificate SHA-256 as assetlinks.json wants it: 32 colon-separated bytes.
_CERT_SHA256_RE = re.compile(r"^([0-9A-F]{2}:){31}[0-9A-F]{2}$")
_ANDROID_PACKAGE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$")
_APPLE_TEAM_ID_RE = re.compile(r"^[A-Z0-9]{10}$")
_IOS_BUNDLE_ID_RE = re.compile(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")


def _normalize_fingerprints(setting: str, values: list[str]) -> list[str]:
    normalized = [value.strip().upper() for value in values]
    if not all(_CERT_SHA256_RE.match(value) for value in normalized):
        raise ValueError(f"{setting} entries must be SHA-256 fingerprints like AA:BB:...:FF")
    return normalized


def _bare_https_origin(value: str) -> str:
    parts = urlsplit(value.strip())
    bare = (
        parts.scheme == "https"
        and parts.hostname is not None
        and "@" not in parts.netloc  # no userinfo, also the empty ``https://@host``
        and parts.path in ("", "/")
        and not parts.query
        and not parts.fragment
    )
    if not bare:
        raise ValueError("PUBLIC_LINK_BASE_URL must be a bare https origin, e.g. https://host")
    return f"https://{parts.netloc.lower()}"


def normalize_database_url(url: str) -> str:
    """Force the asyncpg driver for plain ``postgres://`` / ``postgresql://`` URLs."""
    for prefix in ("postgresql+asyncpg://", "postgresql://", "postgres://"):
        if url.startswith(prefix):
            return "postgresql+asyncpg://" + url[len(prefix) :]
    return url


class Settings(BaseSettings):
    model_config = SettingsConfigDict(extra="ignore", case_sensitive=False)

    region: Region
    environment: Environment = "dev"
    database_url: str
    redis_url: str = "redis://localhost:6379/0"
    jwt_secret: SecretStr

    access_token_ttl_seconds: int = Field(default=15 * 60, ge=60, le=3600)
    refresh_token_ttl_seconds: int = Field(default=30 * 24 * 3600, ge=3600)

    email_code_ttl_seconds: int = Field(default=15 * 60, ge=60)
    email_code_max_attempts: int = Field(default=5, ge=1)
    # Per account and purpose within ``email_code_window_seconds``: at most this
    # many codes are issued, and at most this many wrong guesses are accepted
    # across all of them (a new code does not reset the budget).
    email_code_window_seconds: int = Field(default=24 * 3600, ge=60)
    email_code_daily_cap: int = Field(default=5, ge=1)
    email_code_max_failed_per_window: int = Field(default=10, ge=1)
    # Dev only: the logging e-mail sender prints codes. Forbidden in prod.
    log_email_codes: bool = False

    # Fixed-window limits for unauthenticated auth endpoints: per (IP, email)
    # and per e-mail across all IPs; a coarser per-IP bucket allows
    # ``max_attempts * ip_multiplier``.
    rate_limit_auth_max_attempts: int = Field(default=10, ge=1)
    rate_limit_auth_window_seconds: int = Field(default=15 * 60, ge=1)
    rate_limit_ip_multiplier: int = Field(default=10, ge=1)

    # Argon2id parameters (RFC 9106 "second recommended" profile by default).
    password_hash_time_cost: int = Field(default=3, ge=1)
    password_hash_memory_kib: int = Field(default=64 * 1024, ge=1024)
    password_hash_parallelism: int = Field(default=4, ge=1)

    db_pool_size: int = Field(default=10, ge=1)
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"
    cors_origins: list[str] = Field(default_factory=list)

    # --- relatives: invites and grants (ADR 0005, ADR 0009) ---------------------
    invite_ttl_seconds: int = Field(default=7 * 24 * 3600, ge=60)
    # A guardian link grants full access (hidden medications, dose marking): short-lived.
    guardian_invite_ttl_seconds: int = Field(default=24 * 3600, ge=60)
    # How long the accepter's id stays on a consumed invite so a lost response can be
    # replayed; the retention job (``app.jobs.retention``) clears it afterwards.
    invite_replay_window_seconds: int = Field(default=24 * 3600, ge=60)
    # Invites are deleted this long after their end of life (consumed, revoked or expired).
    invite_retention_days: int = Field(default=30, ge=1)
    # Versions of the invite disclosure screen this server knows (stored on grants).
    supported_disclosure_versions: list[int] = Field(default_factory=lambda: [1])
    max_active_invites_per_profile: int = Field(default=5, ge=1)
    max_access_scopes_per_user: int = Field(default=100, ge=1)
    # A scoped pull records the device's last sync time at most this often (D5 shows it
    # to relatives only floored to the hour, so a finer record would be wasted writes).
    device_touch_interval_seconds: int = Field(default=300, ge=0)
    # ``X-Device-ID`` is chosen by the client, so device rows are capped per user: a new id
    # beyond the cap is refused (409 ``too_many_devices``) unless a device unseen for
    # ``device_stale_after_days`` can be forgotten to make room (app reinstalls churn ids).
    max_devices_per_user: int = Field(default=50, ge=1)
    device_stale_after_days: int = Field(default=90, ge=1)
    grants_list_limit: int = Field(default=500, ge=1)

    # Soft limits stay off until payments exist (TZ §1 monetization).
    feature_soft_limits: bool = False
    soft_limit_relatives: int = Field(default=3, ge=1)
    soft_limit_pdf_reports: int = Field(default=3, ge=1)

    # --- account deletion with a grace period and the managed archive (ADR 0010, D1/D2) -----
    # The hard erase completes within the grace period counted from the request (152-FZ
    # art. 21(5): 30 days): ``erase_after`` is set one job interval early, and the validator
    # refuses a grace shorter than that interval.
    account_deletion_grace_days: int = Field(default=30, ge=1, le=30)
    account_erasure_job_interval_seconds: int = Field(default=3600, ge=60)
    # Users erased per query of the erase job; every user still has its own transaction.
    account_erasure_batch_size: int = Field(default=50, ge=1)
    account_restore_ticket_ttl_seconds: int = Field(default=600, ge=60)
    # A managed profile archived at its owner's erasure is purged this long afterwards.
    managed_archive_retention_days: int = Field(default=365, ge=1)

    # --- invite links and OS link verification (ADR 0009, owner decision D6) -----
    # Per region; the reserved ``.invalid`` TLD never resolves, so a placeholder
    # cannot leak invite traffic to a real host until the owner picks a domain.
    public_link_base_url: str = ""
    android_package_name: str | None = None
    android_cert_sha256s: list[str] = Field(default_factory=list)
    # Fingerprints of debug keystores (per developer machine, not a fixed value):
    # ``prod`` refuses to publish any of them in ``assetlinks.json``.
    android_debug_cert_sha256s: list[str] = Field(default_factory=list)
    apple_team_id: str | None = None
    ios_bundle_id: str | None = None
    # Verification files are fetched by Google and Apple (and their CDNs), not by users.
    well_known_cache_seconds: int = Field(default=3600, ge=0)

    @field_validator("database_url")
    @classmethod
    def _normalize_db_url(cls, value: str) -> str:
        return normalize_database_url(value)

    @field_validator("jwt_secret")
    @classmethod
    def _secret_strength(cls, value: SecretStr) -> SecretStr:
        if len(value.get_secret_value()) < 32:
            raise ValueError("JWT_SECRET must be at least 32 characters")
        return value

    @field_validator("android_cert_sha256s")
    @classmethod
    def _android_certs(cls, value: list[str]) -> list[str]:
        return _normalize_fingerprints("ANDROID_CERT_SHA256S", value)

    @field_validator("android_debug_cert_sha256s")
    @classmethod
    def _android_debug_certs(cls, value: list[str]) -> list[str]:
        return _normalize_fingerprints("ANDROID_DEBUG_CERT_SHA256S", value)

    @field_validator("android_package_name")
    @classmethod
    def _android_package(cls, value: str | None) -> str | None:
        if value is not None and not _ANDROID_PACKAGE_RE.match(value):
            raise ValueError("ANDROID_PACKAGE_NAME is not a valid Android package name")
        return value

    @field_validator("apple_team_id")
    @classmethod
    def _apple_team(cls, value: str | None) -> str | None:
        if value is not None and not _APPLE_TEAM_ID_RE.match(value):
            raise ValueError("APPLE_TEAM_ID must be 10 upper-case letters or digits")
        return value

    @field_validator("ios_bundle_id")
    @classmethod
    def _ios_bundle(cls, value: str | None) -> str | None:
        if value is not None and not _IOS_BUNDLE_ID_RE.match(value):
            raise ValueError("IOS_BUNDLE_ID is not a valid bundle identifier")
        return value

    @field_validator("public_link_base_url")
    @classmethod
    def _link_base_url(cls, value: str) -> str:
        return _bare_https_origin(value) if value else value

    @model_validator(mode="after")
    def _prod_safety(self) -> Self:
        if self.environment == "prod" and self.log_email_codes:
            raise ValueError("LOG_EMAIL_CODES must not be enabled when ENVIRONMENT=prod")
        if self.environment == "prod" and set(self.android_cert_sha256s) & set(
            self.android_debug_cert_sha256s
        ):
            raise ValueError("ANDROID_CERT_SHA256S must not contain a debug certificate in prod")
        if (
            self.environment == "prod"
            and self.android_cert_sha256s
            and not self.android_debug_cert_sha256s
        ):
            # An empty denylist would make the check above pass vacuously.
            raise ValueError("ANDROID_DEBUG_CERT_SHA256S is required in prod with certificates")
        return self

    @model_validator(mode="after")
    def _grace_outlasts_the_job_interval(self) -> Self:
        if (
            self.account_deletion_grace_days * 24 * 3600
            <= self.account_erasure_job_interval_seconds
        ):
            raise ValueError(
                "ACCOUNT_DELETION_GRACE_DAYS must be longer than "
                "ACCOUNT_ERASURE_JOB_INTERVAL_SECONDS"
            )
        return self

    @model_validator(mode="after")
    def _default_link_base_url(self) -> Self:
        if not self.public_link_base_url:
            self.public_link_base_url = f"https://links-{self.region}.pillpal.invalid"
        return self
