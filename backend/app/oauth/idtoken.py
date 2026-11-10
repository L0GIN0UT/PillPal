"""Verification of an OpenID Connect ID token (ADR 0017 section 3), shared by Apple and Google.

Signature first (RS256 or ES256 only, the key chosen by ``kid`` from the provider JWKS, the
algorithm must be the one the key is for), then the claims: issuer, audience (and ``azp``), expiry,
``iat``, the nonce rule and the subject. ``exp``, ``iat`` and the clock are checked here against the
injected ``now``, not by the JWT library. The token is never put into an error or a log.
"""

from __future__ import annotations

import hashlib
import hmac
from collections.abc import Collection
from datetime import UTC, datetime, timedelta
from typing import Any

import jwt
from jwt.exceptions import PyJWTError

from app.oauth.base import VerifiedIdentity
from app.oauth.errors import invalid_provider_token
from app.oauth.jwks import JwksCache

# Pinned: never ``none``, never HS* (a public key must not become a shared secret).
ALGORITHMS = frozenset({"RS256", "ES256"})
MAX_SUBJECT_LENGTH = 255


async def verify_id_token(
    token: str,
    *,
    jwks: JwksCache,
    provider: str,
    issuers: Collection[str],
    audience: str,
    nonce: str | None,
    now: datetime,
    skew_seconds: int,
) -> VerifiedIdentity:
    claims = await _signed_claims(token, jwks, now)
    if claims.get("iss") not in issuers or not _audience_matches(claims, audience):
        raise invalid_provider_token()
    expires_at = _timestamp(claims, "exp")
    issued_at = _timestamp(claims, "iat")
    if expires_at <= now or issued_at > now + timedelta(seconds=skew_seconds):
        raise invalid_provider_token()
    if not _nonce_matches(claims, nonce):
        raise invalid_provider_token()
    subject = claims.get("sub")
    if not isinstance(subject, str) or not 1 <= len(subject) <= MAX_SUBJECT_LENGTH:
        raise invalid_provider_token()
    email = _email(claims)
    return VerifiedIdentity(
        provider=provider,
        subject=subject,
        email=email,
        email_verified=email is not None and _is_true(claims.get("email_verified")),
        assertion_id=hashlib.sha256(token.encode()).hexdigest(),
        expires_at=expires_at,
        issued_at=issued_at,
    )


async def _signed_claims(token: str, jwks: JwksCache, now: datetime) -> dict[str, Any]:
    try:
        header = jwt.get_unverified_header(token)
    except PyJWTError:
        raise invalid_provider_token() from None
    algorithm, kid = header.get("alg"), header.get("kid")
    if algorithm not in ALGORITHMS or not isinstance(kid, str):
        raise invalid_provider_token()
    key = await jwks.key_for(kid, now)
    if key is None or key.algorithm_name != algorithm:
        raise invalid_provider_token()
    try:
        claims = jwt.decode(
            token,
            key.key,
            algorithms=[algorithm],
            options={
                "verify_exp": False,
                "verify_iat": False,
                "verify_nbf": False,
                "verify_aud": False,
                "verify_iss": False,
            },
        )
    except PyJWTError:
        raise invalid_provider_token() from None
    return dict(claims)


def _audience_matches(claims: dict[str, Any], audience: str) -> bool:
    raw = claims.get("aud")
    audiences = [raw] if isinstance(raw, str) else raw
    if not isinstance(audiences, list) or audience not in audiences:
        return False
    # OIDC core 3.1.3.7: several audiences need an ``azp``; when there is one, it is us.
    authorized_party = claims.get("azp")
    if authorized_party is None:
        return len(audiences) == 1
    return bool(authorized_party == audience)


def _timestamp(claims: dict[str, Any], name: str) -> datetime:
    value = claims.get(name)
    if isinstance(value, bool) or not isinstance(value, int | float):
        raise invalid_provider_token()
    try:
        return datetime.fromtimestamp(value, UTC)
    except (OverflowError, OSError, ValueError):
        raise invalid_provider_token() from None


def _nonce_matches(claims: dict[str, Any], nonce: str | None) -> bool:
    carried = claims.get("nonce")
    if nonce is None or not isinstance(carried, str):
        return False
    expected = hashlib.sha256(nonce.encode()).hexdigest()
    return hmac.compare_digest(carried, expected)


def _email(claims: dict[str, Any]) -> str | None:
    email = claims.get("email")
    if not isinstance(email, str) or not email.strip():
        return None
    return email.strip().lower()


def _is_true(value: object) -> bool:
    """Apple sends ``email_verified`` as the string ``"true"``, Google as a boolean."""
    return value is True or value == "true"
