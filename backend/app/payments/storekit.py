"""StoreKit 2 transaction verification, offline (ADR 0018 section 6).

``verify`` takes the signed transaction (compact JWS, ES256) of one account and returns a
``VerifiedPurchase`` or raises ``InvalidPurchase`` with a fixed reason code. The order matters:
nothing in the payload is trusted before the signature is checked, except the signing instant
(``signedDate``), which only selects the moment at which the chain must have been valid.

Claims: ``bundleId``, the product allowlist, ``type`` = ``Non-Consumable``, no family sharing,
``environment`` Production (Sandbox only when allowed; Xcode never), ``appAccountToken`` equal
to the caller's, no revocation. Nothing is sent to Apple, and the JWS is neither stored nor logged.
"""

from __future__ import annotations

import base64
import json
import re
import uuid
from collections.abc import Mapping
from datetime import UTC, datetime, timedelta
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

from app.domain.payments import APP_STORE
from app.payments.base import InvalidPurchase, VerifiedPurchase
from app.payments.storekit_chain import verified_leaf_key

ALGORITHM = "ES256"
JWS_PARTS = 3
SIGNATURE_BYTES = 64  # raw r || s of P-256
# Parts are bounded before they are decoded (a StoreKit header is about 3 KB with its chain).
MAX_HEADER_CHARS = 8192
MAX_PAYLOAD_CHARS = 32768
# A signing instant a little ahead of ours is clock skew; further is a forged date.
SIGNED_DATE_SKEW = timedelta(minutes=5)
NON_CONSUMABLE = "Non-Consumable"
_ORIGINAL_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
_ENVIRONMENTS = {"Production": "production", "Sandbox": "sandbox"}
MALFORMED = "malformed"


def _b64url(part: str) -> bytes:
    try:
        return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))
    except ValueError:
        raise InvalidPurchase(MALFORMED) from None


def _json_object(part: str, limit: int) -> dict[str, Any]:
    if len(part) > limit:
        raise InvalidPurchase(MALFORMED)
    try:
        value = json.loads(_b64url(part))
    except (ValueError, RecursionError):  # bad text, and nesting deeper than the parser allows
        raise InvalidPurchase(MALFORMED) from None
    if not isinstance(value, dict):
        raise InvalidPurchase(MALFORMED)
    return value


def _instant(value: object) -> datetime:
    """Milliseconds since the epoch, as Apple sends them."""
    if isinstance(value, bool) or not isinstance(value, int):
        raise InvalidPurchase(MALFORMED)
    try:
        return datetime.fromtimestamp(value / 1000, UTC)
    except (OverflowError, OSError, ValueError):
        raise InvalidPurchase(MALFORMED) from None


class StoreKitVerifier:
    store = APP_STORE

    def __init__(
        self,
        *,
        root_der: bytes,
        bundle_id: str,
        products: Mapping[str, str],
        allow_sandbox: bool,
    ) -> None:
        self._root_der = root_der
        self._bundle_id = bundle_id
        self._products = dict(products)
        self._allow_sandbox = allow_sandbox

    def verify(self, proof: str, *, account_token: uuid.UUID, now: datetime) -> VerifiedPurchase:
        parts = proof.split(".")
        if len(parts) != JWS_PARTS:
            raise InvalidPurchase(MALFORMED)
        header = _json_object(parts[0], MAX_HEADER_CHARS)
        payload = _json_object(parts[1], MAX_PAYLOAD_CHARS)
        if header.get("alg") != ALGORITHM:
            raise InvalidPurchase(MALFORMED)
        signed_at = _instant(payload.get("signedDate"))
        if signed_at > now + SIGNED_DATE_SKEW:
            raise InvalidPurchase(MALFORMED)
        key = verified_leaf_key(header.get("x5c"), self._root_der, signed_at)
        self._check_signature(key, f"{parts[0]}.{parts[1]}", parts[2])
        return self._claims(payload, account_token, signed_at)

    @staticmethod
    def _check_signature(
        key: ec.EllipticCurvePublicKey, signing_input: str, signature: str
    ) -> None:
        raw = _b64url(signature)
        if len(raw) != SIGNATURE_BYTES:
            raise InvalidPurchase(MALFORMED)
        half = SIGNATURE_BYTES // 2
        der = encode_dss_signature(
            int.from_bytes(raw[:half], "big"), int.from_bytes(raw[half:], "big")
        )
        try:
            key.verify(der, signing_input.encode("ascii"), ec.ECDSA(hashes.SHA256()))
        except InvalidSignature:
            raise InvalidPurchase("bad_signature") from None

    def _claims(
        self, payload: Mapping[str, Any], account_token: uuid.UUID, signed_at: datetime
    ) -> VerifiedPurchase:
        if payload.get("bundleId") != self._bundle_id:
            raise InvalidPurchase("bad_bundle")
        product_id = payload.get("productId")
        if not isinstance(product_id, str) or product_id not in self._products:
            raise InvalidPurchase("bad_product")
        if payload.get("type") != NON_CONSUMABLE:
            raise InvalidPurchase("bad_type")
        ownership = payload.get("inAppOwnershipType")
        if ownership == "FAMILY_SHARED":
            raise InvalidPurchase("family_shared")
        if ownership != "PURCHASED":
            raise InvalidPurchase(MALFORMED)
        environment = self._environment(payload.get("environment"))
        self._check_account(payload.get("appAccountToken"), account_token)
        if payload.get("revocationDate") is not None or payload.get("revocationReason") is not None:
            raise InvalidPurchase("revoked")
        original_id = payload.get("originalTransactionId")
        if not isinstance(original_id, str) or not _ORIGINAL_ID_RE.match(original_id):
            raise InvalidPurchase(MALFORMED)
        purchased_at = _instant(payload.get("purchaseDate"))
        if signed_at < purchased_at:  # a transaction cannot be signed before it happened
            raise InvalidPurchase(MALFORMED)
        return VerifiedPurchase(
            store=self.store,
            product_id=product_id,
            product_kind=self._products[product_id],
            original_transaction_id=original_id,
            environment=environment,
            purchased_at=purchased_at,
        )

    def _environment(self, value: object) -> str:
        environment = _ENVIRONMENTS.get(value) if isinstance(value, str) else None
        if environment is None or (environment == "sandbox" and not self._allow_sandbox):
            raise InvalidPurchase("bad_environment")
        return environment

    @staticmethod
    def _check_account(value: object, expected: uuid.UUID) -> None:
        try:
            claimed = uuid.UUID(value) if isinstance(value, str) else None
        except ValueError:
            claimed = None
        if claimed != expected:
            raise InvalidPurchase("bad_account_token")
