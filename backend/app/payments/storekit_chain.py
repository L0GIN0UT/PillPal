"""The certificate chain of a StoreKit 2 signed transaction (ADR 0018 section 6).

The JWS header carries ``x5c``: leaf, intermediate and, usually, the root. The chain is accepted
when the leaf was issued by the intermediate, the intermediate by the **pinned** Apple Root CA G3
(an embedded root must equal it byte for byte; it is never trusted on its own), both carry
Apple's marker OIDs, the intermediate is a CA, and both were valid when the transaction was signed.

Validity is judged at the signing instant (``signedDate``), not at ``now``: Apple's leaf
certificates are short lived, and a purchase signed in the past must stay verifiable. There is no
OCSP check, so a revoked Apple intermediate is not detected (accepted, ADR 0018 consequences).
"""

from __future__ import annotations

import base64
from datetime import datetime

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from app.payments.base import InvalidPurchase

# Marker extensions Apple puts on its StoreKit signing certificates.
LEAF_MARKER_OID = x509.ObjectIdentifier("1.2.840.113635.100.6.11.1")
INTERMEDIATE_MARKER_OID = x509.ObjectIdentifier("1.2.840.113635.100.6.2.1")
MIN_CHAIN_LENGTH = 2
MAX_CHAIN_LENGTH = 3
BAD_CHAIN = "bad_chain"


def load_certificate(der: bytes) -> x509.Certificate:
    return x509.load_der_x509_certificate(der)


def _decode_chain(x5c: object) -> list[x509.Certificate]:
    if (
        not isinstance(x5c, list)
        or not MIN_CHAIN_LENGTH <= len(x5c) <= MAX_CHAIN_LENGTH
        or not all(isinstance(item, str) for item in x5c)
    ):
        raise InvalidPurchase(BAD_CHAIN)
    try:
        return [load_certificate(base64.b64decode(item, validate=True)) for item in x5c]
    except ValueError:  # bad base64 and bad DER alike
        raise InvalidPurchase(BAD_CHAIN) from None


def _has_marker(cert: x509.Certificate, oid: x509.ObjectIdentifier) -> bool:
    try:
        cert.extensions.get_extension_for_oid(oid)
    except x509.ExtensionNotFound:
        return False
    return True


def _is_ca(cert: x509.Certificate) -> bool:
    try:
        return cert.extensions.get_extension_for_class(x509.BasicConstraints).value.ca
    except x509.ExtensionNotFound:
        return False


def _valid_at(cert: x509.Certificate, moment: datetime) -> bool:
    return cert.not_valid_before_utc <= moment <= cert.not_valid_after_utc


def _issued_by(cert: x509.Certificate, issuer: x509.Certificate) -> bool:
    try:
        cert.verify_directly_issued_by(issuer)
    except (ValueError, TypeError, InvalidSignature):
        return False
    return True


def verified_leaf_key(
    x5c: object, root_der: bytes, signed_at: datetime
) -> ec.EllipticCurvePublicKey:
    """The leaf's public key after the chain checks, or ``InvalidPurchase('bad_chain')``."""
    certs = _decode_chain(x5c)
    leaf, intermediate = certs[0], certs[1]
    root = load_certificate(root_der)
    if len(certs) == MAX_CHAIN_LENGTH and certs[2].public_bytes(
        serialization.Encoding.DER
    ) != root.public_bytes(serialization.Encoding.DER):
        raise InvalidPurchase(BAD_CHAIN)
    markers = _has_marker(leaf, LEAF_MARKER_OID) and _has_marker(
        intermediate, INTERMEDIATE_MARKER_OID
    )
    linked = _issued_by(intermediate, root) and _issued_by(leaf, intermediate)
    dated = _valid_at(leaf, signed_at) and _valid_at(intermediate, signed_at)
    key = leaf.public_key()
    if not (
        markers
        and linked
        and dated
        and _is_ca(intermediate)
        and isinstance(key, ec.EllipticCurvePublicKey)
        and isinstance(key.curve, ec.SECP256R1)
    ):
        raise InvalidPurchase(BAD_CHAIN)
    return key
