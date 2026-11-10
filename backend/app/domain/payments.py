"""Payments rules: stores per region, what a product grants, the account token (ADR 0018 section 6).

Pure, no IO. The stores of a region are fixed here (RuStore Pay is Russian, Google Play is not
offered in RU); the settings and the registry refuse any other pair.
"""

from __future__ import annotations

import hashlib
import hmac
import uuid

APP_STORE = "app_store"
RUSTORE = "rustore"
GOOGLE_PLAY = "google_play"
STORES = (APP_STORE, RUSTORE, GOOGLE_PLAY)
STORES_BY_REGION: dict[str, tuple[str, ...]] = {
    "ru": (RUSTORE, APP_STORE),
    "eu": (APP_STORE, GOOGLE_PLAY),
}
ENVIRONMENTS = ("production", "sandbox")

# The kind of a product in ``PAYMENTS_PRODUCTS`` -> the entitlement kinds it grants (owner
# decision Q2: the one-time remove-ads product lifts the soft limits as well).
REMOVE_ADS = "remove_ads"
PRODUCT_GRANTS: dict[str, tuple[str, ...]] = {REMOVE_ADS: ("ads_removed", "limits_lifted")}


def stores_for(region: str) -> tuple[str, ...]:
    return STORES_BY_REGION.get(region, ())


def app_account_token(key: bytes, user_id: uuid.UUID) -> uuid.UUID:
    """The per-account UUID the client hands to the store at purchase (``appAccountToken``).

    HMAC-SHA256 of the account id under a dedicated per-region key, cut to a version-4 UUID. A
    keyed pseudonym: the store learns nothing about the account, and a transaction bought for
    another account carries another token.
    """
    digest = hmac.new(key, user_id.bytes, hashlib.sha256).digest()
    return uuid.UUID(bytes=digest[:16], version=4)
