"""APNs sender: HTTP/2 provider API with a token-based (ES256 ``.p8``) connection (ADR 0008 §4).

The device token is in the request *path*, so it is validated as hex before it is placed in
a URL, and errors are never rendered from the exception text.
"""

from __future__ import annotations

import re
import uuid
from datetime import UTC, datetime, timedelta
from typing import Any, Final

import httpx
import jwt

from app.push.base import PushMessage, PushProvider, SendResult, safe_code
from app.push.http import Clock, fallback_by_status, guarded, json_object, retry_after, utc_now

HOSTS: Final = {
    "production": "api.push.apple.com",
    "sandbox": "api.sandbox.push.apple.com",
}
# Apple: renew no more than every 20 minutes and no less than every 60; a token older than an
# hour is refused (``ExpiredProviderToken``).
_JWT_LIFETIME = timedelta(minutes=50)
_DEVICE_TOKEN_RE = re.compile(r"^[0-9a-f]{64,200}$")
_APNS_ID_HEADER = "apns-id"

# Neutral key names: Apple sees them, so they say nothing about doses (ADR 0008 §2). The app
# (milestone 3.9) defines the localized strings.
LOC_KEYS: Final = {
    "missed": "relatives_alert_1",
    "resolved": "relatives_alert_2",
    "link_accepted": "relatives_alert_3",
    "link_restored": "relatives_alert_4",
}
# ``m`` stays off the wire: nothing reads it without a notification extension.
_BODY_KEYS = ("v", "t", "a", "p", "g", "s")

_INVALID_TOKEN_REASONS = frozenset(
    {"Unregistered", "ExpiredToken", "BadDeviceToken", "DeviceTokenNotForTopic"}
)
_RETRY_REASONS = frozenset({"TooManyRequests", "InternalServerError", "ServiceUnavailable"})


class ApnsSender:
    provider: PushProvider = "apns"

    def __init__(
        self,
        *,
        team_id: str,
        key_id: str,
        private_key: str,
        topic: str,
        client: httpx.AsyncClient,
        clock: Clock = utc_now,
    ) -> None:
        self._team_id = team_id
        self._key_id = key_id
        self._private_key = private_key
        self._topic = topic
        self._client = client
        self._clock = clock
        self._jwt: str | None = None
        self._jwt_expires_at = datetime.min.replace(tzinfo=UTC)

    def __repr__(self) -> str:
        return "ApnsSender()"

    async def aclose(self) -> None:
        await self._client.aclose()

    def _provider_token(self) -> str:
        now = self._clock()
        if self._jwt is None or now >= self._jwt_expires_at:
            self._jwt = jwt.encode(
                {"iss": self._team_id, "iat": int(now.timestamp())},
                self._private_key,
                algorithm="ES256",
                headers={"kid": self._key_id},
            )
            self._jwt_expires_at = now + _JWT_LIFETIME
        return self._jwt

    def _request_parts(self, message: PushMessage) -> tuple[dict[str, str], dict[str, Any]]:
        payload = message.payload
        wire = payload.to_wire()
        headers = {
            "authorization": f"bearer {self._provider_token()}",
            "apns-topic": self._topic,
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-expiration": str(int(self._clock().timestamp()) + message.ttl_seconds),
            _APNS_ID_HEADER: str(uuid.uuid4()),
        }
        if payload.a is not None:
            headers["apns-collapse-id"] = str(payload.a)  # a UUID: 36 bytes, under the 64 limit
        body: dict[str, Any] = {
            "aps": {
                "alert": {"loc-key": LOC_KEYS[payload.t]},
                "thread-id": str(payload.p),
                "mutable-content": 1,
            }
        }
        body.update({key: wire[key] for key in _BODY_KEYS if key in wire})
        return headers, body

    async def send(self, message: PushMessage) -> SendResult:
        return await guarded("apns", message.delivery_id, lambda: self._send(message))

    async def _send(self, message: PushMessage) -> SendResult:
        host = HOSTS.get(message.apns_environment or "")
        if host is None:
            return SendResult.fatal("missing_environment")
        if not _DEVICE_TOKEN_RE.fullmatch(message.token):
            return SendResult.invalid_token("bad_token_format")
        headers, body = self._request_parts(message)
        response = await self._client.post(
            f"https://{host}/3/device/{message.token}", json=body, headers=headers
        )
        if response.status_code == 200:
            return SendResult.ok()
        return self._map_error(response)

    def _map_error(self, response: httpx.Response) -> SendResult:
        body = json_object(response)
        reason = body.get("reason")
        if not isinstance(reason, str) or safe_code(reason) == "unknown":
            return fallback_by_status(response, self._clock)
        if response.status_code == 403 and reason == "ExpiredProviderToken":
            self._jwt = None
            return SendResult.retry(reason)
        if reason in _INVALID_TOKEN_REASONS:
            return SendResult.invalid_token(reason, _invalid_since(body))
        if reason in _RETRY_REASONS:
            return SendResult.retry(reason, retry_after(response, self._clock))
        return SendResult.fatal(reason)


def _invalid_since(body: dict[str, Any]) -> datetime | None:
    stamp = body.get("timestamp")
    if isinstance(stamp, int) and not isinstance(stamp, bool) and stamp > 0:
        return datetime.fromtimestamp(stamp / 1000, UTC)
    return None
