"""A generated StoreKit 2 certificate chain and signed transactions (ADR 0018 section 6).

Everything here is synthetic: a throwaway root, an intermediate and a leaf, with the Apple marker
OIDs, so the verifier can be exercised without Apple. The root replaces the pinned one through
``PAYMENTS_APPLE_ROOT_CERT_PATH`` (refused in strict environments).
"""

from __future__ import annotations

import base64
import json
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.x509.oid import NameOID

NOW = datetime(2026, 11, 10, 12, 0, tzinfo=UTC)
BUNDLE_ID = "ru.pillpal.test"
PRODUCT_ID = "ru.pillpal.test.remove_ads"
PRODUCTS = {PRODUCT_ID: "remove_ads"}
ORIGINAL_ID = "2000000123456789"
# The account key of the API tests: 32 bytes, distinct from every other test key.
PAYMENTS_KEY_B64 = base64.b64encode(bytes((i * 13 + 7) % 256 for i in range(32))).decode()
INTERMEDIATE_OID = x509.ObjectIdentifier("1.2.840.113635.100.6.2.1")
LEAF_OID = x509.ObjectIdentifier("1.2.840.113635.100.6.11.1")
_NULL_DER = b"\x05\x00"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _name(common_name: str) -> x509.Name:
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])


def _certificate(
    subject: str,
    key: ec.EllipticCurvePrivateKey,
    issuer: str,
    issuer_key: ec.EllipticCurvePrivateKey,
    *,
    ca: bool,
    marker: x509.ObjectIdentifier | None = None,
    not_before: datetime,
    not_after: datetime,
) -> x509.Certificate:
    builder = (
        x509.CertificateBuilder()
        .subject_name(_name(subject))
        .issuer_name(_name(issuer))
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(not_before)
        .not_valid_after(not_after)
        .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
    )
    if marker is not None:
        builder = builder.add_extension(x509.UnrecognizedExtension(marker, _NULL_DER), False)
    return builder.sign(issuer_key, hashes.SHA256())


@dataclass(frozen=True)
class Chain:
    root: x509.Certificate
    intermediate: x509.Certificate
    leaf: x509.Certificate
    leaf_key: ec.EllipticCurvePrivateKey

    @property
    def root_der(self) -> bytes:
        return self.root.public_bytes(serialization.Encoding.DER)

    def x5c(self, *, with_root: bool = True) -> list[str]:
        certs = [self.leaf, self.intermediate] + ([self.root] if with_root else [])
        return [
            base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode() for c in certs
        ]


def make_chain(
    *,
    leaf_marker: x509.ObjectIdentifier | None = LEAF_OID,
    intermediate_marker: x509.ObjectIdentifier | None = INTERMEDIATE_OID,
    intermediate_is_ca: bool = True,
    around: datetime = NOW,
    leaf_not_before: datetime | None = None,
    leaf_not_after: datetime | None = None,
) -> Chain:
    """A synthetic chain valid for a year around ``around`` (the tests' ``now``)."""
    start, end = around - timedelta(days=365), around + timedelta(days=365)
    root_key = ec.generate_private_key(ec.SECP384R1())
    inter_key = ec.generate_private_key(ec.SECP384R1())
    leaf_key = ec.generate_private_key(ec.SECP256R1())
    root = _certificate(
        "Synthetic Root",
        root_key,
        "Synthetic Root",
        root_key,
        ca=True,
        not_before=start,
        not_after=end,
    )
    intermediate = _certificate(
        "Synthetic Intermediate",
        inter_key,
        "Synthetic Root",
        root_key,
        ca=intermediate_is_ca,
        marker=intermediate_marker,
        not_before=start,
        not_after=end,
    )
    leaf = _certificate(
        "Synthetic Leaf",
        leaf_key,
        "Synthetic Intermediate",
        inter_key,
        ca=False,
        marker=leaf_marker,
        not_before=leaf_not_before or start,
        not_after=leaf_not_after or end,
    )
    return Chain(root, intermediate, leaf, leaf_key)


def millis(moment: datetime) -> int:
    return int(moment.timestamp() * 1000)


def transaction(
    account_token: uuid.UUID | str | None,
    *,
    drop: tuple[str, ...] = (),
    at: datetime = NOW,
    original_id: str = ORIGINAL_ID,
    transaction_id: str = "2000000123456790",
    **overrides: Any,
) -> dict[str, Any]:
    """A valid non-consumable transaction payload; ``drop`` removes keys, overrides replace."""
    data: dict[str, Any] = {
        "transactionId": transaction_id,
        "originalTransactionId": original_id,
        "bundleId": BUNDLE_ID,
        "productId": PRODUCT_ID,
        "purchaseDate": millis(at - timedelta(minutes=5)),
        "originalPurchaseDate": millis(at - timedelta(minutes=5)),
        "signedDate": millis(at - timedelta(minutes=1)),
        "type": "Non-Consumable",
        "inAppOwnershipType": "PURCHASED",
        "environment": "Production",
        "quantity": 1,
    }
    if account_token is not None:
        data["appAccountToken"] = str(account_token)
    data.update(overrides)
    for key in drop:
        data.pop(key, None)
    return data


def sign(
    chain: Chain,
    payload: dict[str, Any],
    *,
    alg: str = "ES256",
    x5c: list[str] | None = None,
    key: ec.EllipticCurvePrivateKey | None = None,
) -> str:
    """A compact JWS signed by the chain's leaf key (or ``key``), ES256 raw ``r || s``."""
    header = {"alg": alg, "x5c": x5c if x5c is not None else chain.x5c()}
    signing_input = b64url(json.dumps(header).encode()) + "." + b64url(json.dumps(payload).encode())
    der = (key or chain.leaf_key).sign(signing_input.encode(), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    return signing_input + "." + b64url(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
