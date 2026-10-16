"""Application settings, loaded from environment variables.

One codebase is deployed per data region (TZ §1): ``REGION`` is mandatory and
every stand only ever serves accounts of its own region.
"""

from __future__ import annotations

from typing import Literal

from pydantic import Field, SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

Region = Literal["ru", "eu"]


def normalize_database_url(url: str) -> str:
    """Force the asyncpg driver for plain ``postgres://`` / ``postgresql://`` URLs."""
    for prefix in ("postgresql+asyncpg://", "postgresql://", "postgres://"):
        if url.startswith(prefix):
            return "postgresql+asyncpg://" + url[len(prefix) :]
    return url


class Settings(BaseSettings):
    model_config = SettingsConfigDict(extra="ignore", case_sensitive=False)

    region: Region
    database_url: str
    redis_url: str = "redis://localhost:6379/0"
    jwt_secret: SecretStr

    access_token_ttl_seconds: int = Field(default=15 * 60, ge=60, le=3600)
    refresh_token_ttl_seconds: int = Field(default=30 * 24 * 3600, ge=3600)

    email_code_ttl_seconds: int = Field(default=15 * 60, ge=60)
    email_code_max_attempts: int = Field(default=5, ge=1)
    # Dev only: the logging e-mail sender prints codes. Never enable in production.
    log_email_codes: bool = False

    # Fixed-window limits for unauthenticated auth endpoints, per (IP, email).
    # A coarser per-IP bucket allows ``max_attempts * ip_multiplier``.
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
