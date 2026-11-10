"""Settings of the account data export (Phase 5.5, ADR 0016 sections 8 and 9), a mixin of
``app.config.Settings``. ``Settings`` adds the cross-field checks that need the other secrets."""

from __future__ import annotations

import base64
import binascii
from typing import Self

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings

KEY_BYTES = 32
MAX_EXPORT_BYTES = 64 * 1024 * 1024
MIN_KEY_ID = 1
MAX_KEY_ID = 255


def decode_key(value: str) -> bytes:
    """A keyring entry: 32 random bytes, base64. Strict alphabet and length, no padding games."""
    try:
        raw = base64.b64decode(value.strip(), validate=True)
    except (binascii.Error, ValueError):
        raise ValueError("every data encryption key must be base64") from None
    if len(raw) != KEY_BYTES:
        raise ValueError(f"every data encryption key must decode to {KEY_BYTES} bytes")
    return raw


class ExportSettings(BaseSettings):
    # Off until the app offers it (milestone A1); every export endpoint answers 403 while off.
    feature_data_export: bool = False
    # ``{id: base64}`` with ids 1..255 (the id is the first byte of a blob) and the id used for
    # new writes. Each key is 32 random bytes. Decoded and checked at startup.
    data_encryption_keys: dict[int, SecretStr] = Field(default_factory=dict)
    data_encryption_key_id: int | None = Field(default=None, ge=MIN_KEY_ID, le=MAX_KEY_ID)

    # A ready archive can be downloaded once, for this long.
    export_ttl_hours: int = Field(default=24, ge=1)
    # A new request within this long of an export that was not downloaded is refused.
    export_cooldown_seconds: int = Field(default=3600, ge=0)
    # Over this (compressed) size the export fails with ``export_too_large``. The archive is held
    # in memory and in a ``bytea`` (and the size is an ``integer`` column): 64 MiB is the ceiling
    # until the format streams (ADR 0016 Negative).
    export_max_bytes: int = Field(default=MAX_EXPORT_BYTES, ge=1024, le=MAX_EXPORT_BYTES)
    # Metadata rows (no archive) are deleted this long after the request.
    export_retention_days: int = Field(default=7, ge=1)
    # A claimed build is taken over by another run after this long without a result. Longer than
    # the worker's job timeout (600 s).
    export_build_lease_seconds: int = Field(default=900, ge=60)
    # Builds per cron run (one per minute); a run builds at most one export per account.
    export_builds_per_run: int = Field(default=1, ge=1)
    # Exports an account may have in 24 hours (failed ones do not count).
    export_max_per_day: int = Field(default=3, ge=1)
    # Downloads served at once by one API process (each holds the archive in memory); more get 503.
    export_download_concurrency: int = Field(default=2, ge=1)
    # Per user, across IPs: status polling and download attempts per window.
    export_rate_window_seconds: int = Field(default=60, ge=1)
    export_status_rate_limit: int = Field(default=60, ge=1)
    export_download_rate_limit: int = Field(default=10, ge=1)

    @field_validator("data_encryption_keys")
    @classmethod
    def _keys_decode(cls, value: dict[int, SecretStr]) -> dict[int, SecretStr]:
        seen: set[bytes] = set()
        for key_id, secret in value.items():
            if not MIN_KEY_ID <= key_id <= MAX_KEY_ID:
                raise ValueError(f"DATA_ENCRYPTION_KEYS ids are {MIN_KEY_ID}..{MAX_KEY_ID}")
            raw = decode_key(secret.get_secret_value())
            if raw in seen:
                raise ValueError("DATA_ENCRYPTION_KEYS must not repeat a key")
            seen.add(raw)
        return value

    @model_validator(mode="after")
    def _current_key_is_in_the_keyring(self) -> Self:
        if self.data_encryption_key_id is not None and (
            self.data_encryption_key_id not in self.data_encryption_keys
        ):
            raise ValueError("DATA_ENCRYPTION_KEY_ID is not in DATA_ENCRYPTION_KEYS")
        if self.data_encryption_keys and self.data_encryption_key_id is None:
            raise ValueError("DATA_ENCRYPTION_KEY_ID is required with DATA_ENCRYPTION_KEYS")
        return self

    @model_validator(mode="after")
    def _archives_expire_before_their_metadata_is_deleted(self) -> Self:
        # The retention delete never touches ``ready`` rows; this keeps them from outliving it.
        if self.export_ttl_hours > self.export_retention_days * 24:
            raise ValueError("EXPORT_TTL_HOURS must not exceed EXPORT_RETENTION_DAYS x 24")
        return self

    @model_validator(mode="after")
    def _export_needs_a_keyring(self) -> Self:
        # An export that cannot be encrypted must not be offered, in any environment.
        if self.feature_data_export and not self.data_encryption_keys:
            raise ValueError("FEATURE_DATA_EXPORT needs DATA_ENCRYPTION_KEYS")
        return self

    def decoded_data_encryption_keys(self) -> dict[int, bytes]:
        return {
            key_id: decode_key(secret.get_secret_value())
            for key_id, secret in self.data_encryption_keys.items()
        }
