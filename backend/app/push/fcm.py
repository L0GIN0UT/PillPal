"""FCM HTTP v1 sender (ADR 0008 §3).

Authentication is a service-account JWT (RS256) exchanged for an OAuth2 access token at the
*hard-coded* Google token endpoint: the key file's own ``token_uri`` is ignored, so a
tampered key file cannot make the server post its signed assertion elsewhere. The access
token is cached until shortly before it expires.
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Final

import httpx
import jwt

from app.push.base import PushMessage, PushProvider, SendResult, safe_code
from app.push.http import (
    Clock,
    fallback_by_status,
    guarded,
    http_code,
    json_object,
    retry_after,
    utc_now,
)

OAUTH_TOKEN_URL: Final = "https://oauth2.googleapis.com/token"  # noqa: S105 - a URL, not a secret
SEND_URL_TEMPLATE: Final = "https://fcm.googleapis.com/v1/projects/{project_id}/messages:send"
OAUTH_SCOPE: Final = "https://www.googleapis.com/auth/firebase.messaging"
_ASSERTION_TTL = timedelta(hours=1)
# Renew this long before the access token expires.
_TOKEN_SKEW = timedelta(seconds=60)
_JWT_BEARER = "urn:ietf:params:oauth:grant-type:jwt-bearer"

_INVALID_TOKEN_CODES = frozenset({"UNREGISTERED"})
_FATAL_CODES = frozenset(
    {"SENDER_ID_MISMATCH", "THIRD_PARTY_AUTH_ERROR", "PERMISSION_DENIED", "INVALID_ARGUMENT"}
)
_RETRY_CODES = frozenset({"QUOTA_EXCEEDED", "UNAVAILABLE", "INTERNAL", "RESOURCE_EXHAUSTED"})


@dataclass
class _AccessToken:
    value: str
    expires_at: datetime


def _error_code(error: dict[str, Any]) -> str | None:
    """FCM's ``errorCode`` detail, else the canonical ``status``."""
    for detail in error.get("details") or ():
        if isinstance(detail, dict) and isinstance(detail.get("errorCode"), str):
            return str(detail["errorCode"])
    status = error.get("status")
    return status if isinstance(status, str) else None


def _refers_to_token(error: dict[str, Any]) -> bool:
    for detail in error.get("details") or ():
        for violation in detail.get("fieldViolations") or () if isinstance(detail, dict) else ():
            field = violation.get("field") if isinstance(violation, dict) else None
            if isinstance(field, str) and field.endswith("token"):
                return True
    return False


class FcmSender:
    provider: PushProvider = "fcm"

    def __init__(
        self,
        *,
        project_id: str,
        service_account_json: str,
        client: httpx.AsyncClient,
        clock: Clock = utc_now,
    ) -> None:
        account = json.loads(service_account_json)
        self._client_email: str = account["client_email"]
        self._private_key: str = account["private_key"]
        self._key_id: str | None = account.get("private_key_id")
        self._send_url = SEND_URL_TEMPLATE.format(project_id=project_id)
        self._client = client
        self._clock = clock
        self._access: _AccessToken | None = None
        self._lock = asyncio.Lock()

    def __repr__(self) -> str:
        return "FcmSender()"

    async def aclose(self) -> None:
        await self._client.aclose()

    # -- OAuth ---------------------------------------------------------------------------

    def _assertion(self, now: datetime) -> str:
        claims = {
            "iss": self._client_email,
            "scope": OAUTH_SCOPE,
            "aud": OAUTH_TOKEN_URL,
            "iat": int(now.timestamp()),
            "exp": int((now + _ASSERTION_TTL).timestamp()),
        }
        headers = {"kid": self._key_id} if self._key_id else None
        return jwt.encode(claims, self._private_key, algorithm="RS256", headers=headers)

    async def _fetch_access_token(self) -> _AccessToken | SendResult:
        now = self._clock()
        response = await self._client.post(
            OAUTH_TOKEN_URL,
            data={"grant_type": _JWT_BEARER, "assertion": self._assertion(now)},
        )
        if response.status_code == 200:
            body = json_object(response)
            value, lifetime = body.get("access_token"), body.get("expires_in")
            if isinstance(value, str) and value and isinstance(lifetime, int | float):
                return _AccessToken(value, now + timedelta(seconds=lifetime))
            return SendResult.fatal("oauth_bad_response")
        if response.status_code == 429 or response.status_code >= 500:
            return SendResult.retry("oauth_unavailable", retry_after(response, self._clock))
        return SendResult.fatal("oauth_rejected")  # bad key or clock: configuration

    async def _access_token(self) -> str | SendResult:
        async with self._lock:
            cached = self._access
            if cached is None or self._clock() >= cached.expires_at - _TOKEN_SKEW:
                fetched = await self._fetch_access_token()
                if isinstance(fetched, SendResult):
                    return fetched
                self._access = cached = fetched
            return cached.value

    # -- send ----------------------------------------------------------------------------

    async def send(self, message: PushMessage) -> SendResult:
        return await guarded("fcm", message.delivery_id, lambda: self._send(message))

    async def _send(self, message: PushMessage) -> SendResult:
        token = await self._access_token()
        if isinstance(token, SendResult):
            return token
        data = {key: str(value) for key, value in message.payload.to_wire().items()}
        body = {
            "message": {
                "token": message.token,
                "data": data,
                # No collapse key: at most four can be active, and alerts must not replace
                # each other. The device dedupes by notification id.
                "android": {"priority": "HIGH", "ttl": f"{message.ttl_seconds}s"},
            }
        }
        response = await self._client.post(
            self._send_url, json=body, headers={"Authorization": f"Bearer {token}"}
        )
        if response.status_code == 200:
            return SendResult.ok()
        return self._map_error(response)

    def _map_error(self, response: httpx.Response) -> SendResult:
        error = json_object(response).get("error")
        error = error if isinstance(error, dict) else {}
        code = _error_code(error)
        if code is None:
            return fallback_by_status(response, self._clock)
        shown = safe_code(code)
        if code in _INVALID_TOKEN_CODES or (code == "INVALID_ARGUMENT" and _refers_to_token(error)):
            return SendResult.invalid_token(shown)
        if code == "UNAUTHENTICATED":
            self._access = None  # the OAuth token was refused: mint a new one next time
            return SendResult.retry(shown)
        if code in _RETRY_CODES:
            return SendResult.retry(shown, retry_after(response, self._clock))
        if code in _FATAL_CODES:
            return SendResult.fatal(shown)
        if response.status_code == 429 or response.status_code >= 500:
            return SendResult.retry(shown, retry_after(response, self._clock))
        return SendResult.fatal(shown if shown != "unknown" else http_code(response.status_code))
