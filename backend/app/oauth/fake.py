"""Test double for every provider (dev and test only; ``Settings`` refuses it elsewhere).

The assertion is a JSON object: ``sub`` (required), ``email``, ``email_verified``, ``nonce`` (the
sha256 hex of the raw server nonce), ``jti``, ``exp`` (unix seconds) and ``fail: "unreachable"``
to play a provider timeout. It proves nothing, which is why it never runs in staging or prod.
"""

from __future__ import annotations

import hashlib
import json
from datetime import UTC, datetime, timedelta
from typing import Any

from app.oauth.base import VerifiedIdentity
from app.oauth.errors import invalid_provider_token, provider_unreachable

DEFAULT_LIFETIME = timedelta(minutes=5)
MAX_SUBJECT_LENGTH = 255


def nonce_digest(raw_nonce: str) -> str:
    """What a provider puts in the token: the sha256 of the raw nonce."""
    return hashlib.sha256(raw_nonce.encode()).hexdigest()


class FakeProvider:
    uses_nonce = True

    def __init__(self, name: str) -> None:
        self.name = name

    async def verify(
        self,
        assertion: str,
        *,
        nonce: str | None,
        platform: str,
        code_verifier: str | None,
        now: datetime,
        device_id: str | None = None,
    ) -> VerifiedIdentity:
        claims = _parse(assertion)
        if claims.get("fail") == "unreachable":
            raise provider_unreachable()
        subject = claims.get("sub")
        if not isinstance(subject, str) or not 1 <= len(subject) <= MAX_SUBJECT_LENGTH:
            raise invalid_provider_token()
        if nonce is None or claims.get("nonce") != nonce_digest(nonce):
            raise invalid_provider_token()
        expires_at = _timestamp(claims, "exp", default=now + DEFAULT_LIFETIME)
        if expires_at <= now:
            raise invalid_provider_token()
        email = claims.get("email")
        email = email.strip().lower() if isinstance(email, str) and email.strip() else None
        jti = claims.get("jti")
        assertion_id = (
            jti if isinstance(jti, str) and jti else hashlib.sha256(assertion.encode()).hexdigest()
        )
        return VerifiedIdentity(
            provider=self.name,
            subject=subject,
            email=email,
            email_verified=email is not None and claims.get("email_verified") is True,
            assertion_id=assertion_id,
            expires_at=expires_at,
            issued_at=_timestamp(claims, "iat", default=now),
        )


def _parse(assertion: str) -> dict[str, Any]:
    try:
        claims = json.loads(assertion)
    except ValueError:
        raise invalid_provider_token() from None
    if not isinstance(claims, dict):
        raise invalid_provider_token()
    return claims


def _timestamp(claims: dict[str, Any], name: str, *, default: datetime) -> datetime:
    if name not in claims:
        return default
    value = claims[name]
    if isinstance(value, bool) or not isinstance(value, int | float):
        raise invalid_provider_token()
    try:
        return datetime.fromtimestamp(value, UTC)
    except (OverflowError, OSError, ValueError):
        raise invalid_provider_token() from None
