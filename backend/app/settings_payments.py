"""Settings of payments (ADR 0018 sections 6 and 7), a mixin of ``app.config.Settings``.

Off by default. The rules that need other settings (environment, region, the other secrets) are in
``check_payments_settings``, which ``Settings`` calls from one model validator. Strict environments
(staging, prod) refuse a half-configured payment setup, a sandbox in prod, a replacement root
certificate, and soft limits without payments (TZ section 1: limits only together with payment).
"""

from __future__ import annotations

import base64
import binascii
import re
from typing import TYPE_CHECKING

from pydantic import Field, SecretStr, field_validator
from pydantic_settings import BaseSettings

from app.domain.payments import PRODUCT_GRANTS, STORES, stores_for
from app.settings_catalog import STRICT_ENVIRONMENTS

if TYPE_CHECKING:
    from app.config import Settings

PAYMENTS_KEY_BYTES = 32
MAX_BODY_BYTES_LIMIT = 64 * 1024
MIN_BODY_BYTES_LIMIT = 1024
_BUNDLE_ID_RE = re.compile(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")
MAX_PRODUCT_ID_LENGTH = 255


class PaymentSettings(BaseSettings):
    feature_payments: bool = False
    # Store product id -> kind of product (``remove_ads``), the allowlist of purchasable products.
    payments_products: dict[str, str] = Field(default_factory=dict)
    # Default: every store of the region (``app.domain.payments``); a subset narrows it, any other
    # store is refused at startup.
    payments_stores: list[str] | None = None
    payments_apple_bundle_id: str | None = None
    # The numeric App Store id; kept for the server notifications of a later slice.
    payments_apple_app_id: int | None = Field(default=None, ge=1)
    # Transactions of the sandbox environment; refused in prod.
    payments_allow_sandbox: bool = False
    # Replaces the pinned Apple Root CA G3 (a generated test chain); refused in strict environments.
    payments_apple_root_cert_path: str | None = None
    # 32 random bytes, base64, per region, distinct from every other key; not rotated while
    # purchases exist (every account's ``appAccountToken`` would change).
    payments_app_account_key: SecretStr | None = None
    payments_max_body_bytes: int = Field(
        default=16 * 1024, ge=MIN_BODY_BYTES_LIMIT, le=MAX_BODY_BYTES_LIMIT
    )
    # Attempts per window, per account and per source address (``app.ratelimit``).
    payments_rate_limit_attempts: int = Field(default=10, ge=1)
    payments_rate_limit_window_seconds: int = Field(default=900, ge=1)

    @field_validator(
        "payments_app_account_key",
        "payments_apple_bundle_id",
        "payments_apple_root_cert_path",
        mode="before",
    )
    @classmethod
    def _blank_payments_value_is_unset(cls, value: object) -> object:
        return None if isinstance(value, str) and not value.strip() else value

    @field_validator("payments_app_account_key")
    @classmethod
    def _payments_key_is_32_bytes(cls, value: SecretStr | None) -> SecretStr | None:
        if value is not None and _decode_key(value) is None:
            # Never echo the value.
            raise ValueError("PAYMENTS_APP_ACCOUNT_KEY must be 32 random bytes, base64-encoded")
        return value

    @field_validator("payments_apple_bundle_id")
    @classmethod
    def _payments_bundle_id(cls, value: str | None) -> str | None:
        if value is not None and not _BUNDLE_ID_RE.match(value):
            raise ValueError("PAYMENTS_APPLE_BUNDLE_ID is not a valid bundle identifier")
        return value

    @field_validator("payments_products")
    @classmethod
    def _payments_products(cls, value: dict[str, str]) -> dict[str, str]:
        for product_id, kind in value.items():
            if not 1 <= len(product_id) <= MAX_PRODUCT_ID_LENGTH or kind not in PRODUCT_GRANTS:
                raise ValueError(
                    "PAYMENTS_PRODUCTS maps a store product id to a known kind: "
                    f"{', '.join(PRODUCT_GRANTS)}"
                )
        return value

    def payments_key_bytes(self) -> bytes | None:
        """The decoded account key, or ``None`` when it is not configured."""
        key = self.payments_app_account_key
        return None if key is None else _decode_key(key)


def _decode_key(value: SecretStr) -> bytes | None:
    try:
        raw = base64.b64decode(value.get_secret_value(), validate=True)
    except (binascii.Error, ValueError):
        return None
    return raw if len(raw) == PAYMENTS_KEY_BYTES else None


def _other_secrets(settings: Settings) -> set[str | bytes]:
    jwt = settings.jwt_secret.get_secret_value()
    others: set[str | bytes] = {jwt.strip(), jwt.encode()}
    if settings.promo_code_hmac_key is not None:
        others.add(settings.promo_code_hmac_key.get_secret_value().strip())
        promo_bytes = settings.promo_key_bytes()
        if promo_bytes is not None:
            others.add(promo_bytes)
    others.update(settings.decoded_data_encryption_keys().values())
    others.update(
        secret.get_secret_value().strip() for secret in settings.data_encryption_keys.values()
    )
    return others


def check_payments_settings(settings: Settings) -> None:
    """Cross-field rules; raises ``ValueError`` with a message that never holds a secret."""
    strict = settings.environment in STRICT_ENVIRONMENTS
    allowed = stores_for(settings.region)
    for store in settings.payments_stores or ():
        if store not in STORES or store not in allowed:
            raise ValueError(
                f"PAYMENTS_STORES: {store!r} is not offered in REGION={settings.region}"
            )
    key = settings.payments_app_account_key
    if key is not None:
        key_bytes = settings.payments_key_bytes()
        if key.get_secret_value().strip() in _other_secrets(settings) or (
            key_bytes is not None and key_bytes in _other_secrets(settings)
        ):
            raise ValueError(
                "PAYMENTS_APP_ACCOUNT_KEY must differ from JWT_SECRET, PROMO_CODE_HMAC_KEY and "
                "every DATA_ENCRYPTION_KEYS key"
            )
    if settings.environment == "prod" and settings.payments_allow_sandbox:
        raise ValueError("PAYMENTS_ALLOW_SANDBOX must not be enabled when ENVIRONMENT=prod")
    if strict and settings.payments_apple_root_cert_path is not None:
        raise ValueError(
            "PAYMENTS_APPLE_ROOT_CERT_PATH must not be set when ENVIRONMENT=staging or prod"
        )
    if strict and settings.feature_soft_limits and not settings.feature_payments:
        raise ValueError("FEATURE_SOFT_LIMITS=true requires FEATURE_PAYMENTS=true")
    if strict and settings.feature_payments:
        missing = [
            name
            for name, present in (
                ("PAYMENTS_APP_ACCOUNT_KEY", key is not None),
                ("PAYMENTS_APPLE_BUNDLE_ID", settings.payments_apple_bundle_id is not None),
                ("PAYMENTS_PRODUCTS", bool(settings.payments_products)),
            )
            if not present
        ]
        if missing:
            raise ValueError(
                f"FEATURE_PAYMENTS=true in staging or prod requires {', '.join(missing)}"
            )
