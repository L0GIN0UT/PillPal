"""Apple's token endpoint, called by the server (ADR 0017 section 9).

* The client secret is an ES256 JWT signed with the Sign in with Apple key (team id, key id and the
  PEM from ``OAUTH_APPLE_PRIVATE_KEY[_FILE]``, parsed once at construction). It is cached in memory
  and renewed at half of its lifetime (``OAUTH_APPLE_CLIENT_SECRET_TTL_SECONDS``, at most Apple's
  6 months); signing runs in a thread so the event loop is never blocked.
* ``exchange_code`` trades the authorization code for the refresh token; ``revoke`` ends it.

Every failure is an :class:`AppleTokenError` without a message: neither the code, the tokens nor
the response body ever reach an exception text or a log.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Self

import httpx
import jwt
from cryptography.hazmat.primitives.asymmetric import ec
from jwt.exceptions import PyJWTError

from app.config import Settings
from app.oauth.apple import APPLE_ISSUER
from app.oauth.apple_key import load_apple_key
from app.observability import get_logger

APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token"  # noqa: S105 (an endpoint, not a secret)
APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke"
MAX_REFRESH_TOKEN_LENGTH = 4096

_log = get_logger("pillpal.oauth")


class AppleTokenError(Exception):
    """Apple could not be asked, refused, or answered with something unusable."""


@dataclass(frozen=True)
class AppleExchange:
    refresh_token: str
    # ``sub`` of the ID token in the same answer (read straight from Apple over TLS): the caller
    # compares it with the verified subject, so a code of another user is never attached.
    subject: str | None


class AppleTokenClient:
    def __init__(
        self,
        http: httpx.AsyncClient,
        *,
        client_id: str,
        team_id: str,
        key_id: str,
        private_key: ec.EllipticCurvePrivateKey,
        secret_ttl_seconds: int,
    ) -> None:
        self._http = http
        self._client_id = client_id
        self._team_id = team_id
        self._key_id = key_id
        self._key = private_key
        self._ttl = timedelta(seconds=secret_ttl_seconds)
        self._cached: tuple[str, datetime] | None = None  # (client secret, issued at)

    @classmethod
    def from_settings(cls, settings: Settings, http: httpx.AsyncClient) -> Self | None:
        """The client, or ``None`` unless client id, team id, key id and a valid key are all set.

        A key that does not parse is logged (no content) and leaves Apple token handling off;
        strict environments never get here with one, ``Settings`` refuses to start.
        """
        key = settings.oauth_apple_private_key
        if not (
            settings.oauth_apple_client_id
            and settings.oauth_apple_team_id
            and settings.oauth_apple_key_id
            and key is not None
        ):
            return None
        private_key = load_apple_key(key.get_secret_value())
        if private_key is None:
            _log.error("apple_key_invalid")
            return None
        return cls(
            http,
            client_id=settings.oauth_apple_client_id,
            team_id=settings.oauth_apple_team_id,
            key_id=settings.oauth_apple_key_id,
            private_key=private_key,
            secret_ttl_seconds=settings.oauth_apple_client_secret_ttl_seconds,
        )

    async def client_secret(self, now: datetime) -> str:
        if self._cached is not None:
            secret, issued_at = self._cached
            if timedelta(0) <= now - issued_at < self._ttl / 2:
                return secret
        secret = await asyncio.to_thread(self._sign, now)
        self._cached = (secret, now)
        return secret

    def _sign(self, now: datetime) -> str:
        try:
            return jwt.encode(
                {
                    "iss": self._team_id,
                    "iat": int(now.timestamp()),
                    "exp": int((now + self._ttl).timestamp()),
                    "aud": APPLE_ISSUER,
                    "sub": self._client_id,
                },
                self._key,
                algorithm="ES256",
                headers={"kid": self._key_id},
            )
        except (ValueError, TypeError, PyJWTError):
            raise AppleTokenError from None

    async def exchange_code(self, code: str, now: datetime) -> AppleExchange:
        answer = await self._post(
            APPLE_TOKEN_URL, {"grant_type": "authorization_code", "code": code}, now
        )
        try:
            document: Any = answer.json()
        except ValueError:
            raise AppleTokenError from None
        refresh_token = document.get("refresh_token") if isinstance(document, dict) else None
        if (
            not isinstance(refresh_token, str)
            or not 0 < len(refresh_token) <= MAX_REFRESH_TOKEN_LENGTH
        ):
            raise AppleTokenError
        return AppleExchange(refresh_token, _subject_of(document.get("id_token")))

    async def revoke(
        self, refresh_token: str, now: datetime, *, timeout_seconds: float | None = None
    ) -> None:
        """End the token; ``timeout_seconds`` replaces the client default for this call."""
        await self._post(
            APPLE_REVOKE_URL,
            {"token": refresh_token, "token_type_hint": "refresh_token"},
            now,
            timeout_seconds=timeout_seconds,
        )

    async def _post(
        self, url: str, form: dict[str, str], now: datetime, *, timeout_seconds: float | None = None
    ) -> httpx.Response:
        data = {
            "client_id": self._client_id,
            "client_secret": await self.client_secret(now),
            **form,
        }
        try:
            if timeout_seconds is None:
                response = await self._http.post(url, data=data)
            else:
                response = await self._http.post(url, data=data, timeout=timeout_seconds)
            response.raise_for_status()
        except httpx.HTTPError:
            raise AppleTokenError from None
        return response


def _subject_of(id_token: object) -> str | None:
    if not isinstance(id_token, str):
        return None
    try:
        # Unverified on purpose: it came from Apple over TLS in the answer to our own request.
        subject = jwt.decode(id_token, options={"verify_signature": False}).get("sub")
    except PyJWTError:
        return None
    return subject if isinstance(subject, str) else None
