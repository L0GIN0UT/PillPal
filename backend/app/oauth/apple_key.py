"""Loading the Sign in with Apple key (a P-256 PKCS#8 PEM). Pure: no IO, nothing logged."""

from __future__ import annotations

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec


def load_apple_key(pem: str) -> ec.EllipticCurvePrivateKey | None:
    """The key, or ``None`` when ``pem`` is not an unencrypted P-256 private key.

    A literal ``\\n`` is accepted for a key pasted into an environment variable.
    """
    try:
        key = serialization.load_pem_private_key(pem.replace("\\n", "\n").encode(), password=None)
    except (ValueError, TypeError):
        return None
    if isinstance(key, ec.EllipticCurvePrivateKey) and isinstance(key.curve, ec.SECP256R1):
        return key
    return None
