"""Settings of promo codes (ADR 0018 sections 3 and 4), a mixin of ``app.config.Settings``.

The key is a per-region secret: a code of one region fails in the other. Rules that need other
settings (not the JWT secret, required in strict environments) live in ``Settings``.
"""

from __future__ import annotations

import base64
import binascii

from pydantic import Field, SecretStr, field_validator
from pydantic_settings import BaseSettings

from app.domain.promo import MAX_INPUT_LENGTH, MIN_CODE_LENGTH

PROMO_KEY_BYTES = 32
# A code shown in groups of four ("ABCD-EFGH-...") must still fit the endpoint's input limit.
MAX_CODE_LENGTH = MAX_INPUT_LENGTH * 3 // 4


class PromoSettings(BaseSettings):
    feature_promo_codes: bool = False
    # 32 random bytes, base64-encoded; decoded and length-checked at startup.
    promo_code_hmac_key: SecretStr | None = None
    promo_code_length: int = Field(default=20, ge=MIN_CODE_LENGTH, le=MAX_CODE_LENGTH)

    # Failed redeems per account within the lockout window (a day, counted from the first
    # failure) before 429 ``promo_locked``.
    promo_max_failed_per_day: int = Field(default=5, ge=1)
    promo_lockout_window_seconds: int = Field(default=24 * 3600, ge=1)
    # More failures than this in the window, counted over all accounts, trip the breaker: an
    # alert (log code ``promo_breaker_tripped``). For the block period it also refuses callers
    # that already failed today; nobody else is blocked.
    promo_breaker_threshold: int = Field(default=200, ge=1)
    promo_breaker_window_seconds: int = Field(default=3600, ge=1)
    promo_breaker_block_seconds: int = Field(default=900, ge=1)
    # Attempts (not failures) per window, per account and per source address.
    promo_rate_limit_per_user: int = Field(default=10, ge=1)
    promo_rate_limit_per_ip: int = Field(default=30, ge=1)
    promo_rate_limit_window_seconds: int = Field(default=900, ge=1)

    @field_validator("promo_code_hmac_key", mode="before")
    @classmethod
    def _blank_key_is_unset(cls, value: object) -> object:
        return None if isinstance(value, str) and not value.strip() else value

    @field_validator("promo_code_hmac_key")
    @classmethod
    def _key_is_32_bytes(cls, value: SecretStr | None) -> SecretStr | None:
        if value is not None and _decode_key(value) is None:
            # Never echo the value.
            raise ValueError("PROMO_CODE_HMAC_KEY must be 32 random bytes, base64-encoded")
        return value

    def promo_key_bytes(self) -> bytes | None:
        """The decoded key, or ``None`` when it is not configured."""
        return None if self.promo_code_hmac_key is None else _decode_key(self.promo_code_hmac_key)


def _decode_key(value: SecretStr) -> bytes | None:
    try:
        raw = base64.b64decode(value.get_secret_value(), validate=True)
    except (binascii.Error, ValueError):
        return None
    return raw if len(raw) == PROMO_KEY_BYTES else None
