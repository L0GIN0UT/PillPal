"""RuStore Push sender (HTTP API, ADR 0008 §5): RU region only.

The API accepts ``token``, ``data`` and ``android.ttl`` (no priority, no collapse key).
Unverified until a real project exists (ADR 0008 §5, "to verify in 3.4"): the exact statuses
of an invalid service key (401 or 403) and whether a 429 carries ``Retry-After``. Both are
handled defensively: 401 and 403 are fatal, and ``Retry-After`` is honoured when present.
"""

from __future__ import annotations

from typing import Any, Final

import httpx

from app.push.base import PushMessage, PushProvider, SendResult, safe_code
from app.push.http import Clock, fallback_by_status, guarded, json_object, retry_after, utc_now

SEND_URL_TEMPLATE: Final = "https://vkpns.rustore.ru/v1/projects/{project_id}/messages:send"

_RETRY_STATUSES = frozenset({"TOO_MANY_REQUESTS", "INTERNAL"})
_FATAL_STATUSES = frozenset({"PERMISSION_DENIED", "UNAUTHENTICATED"})


class RuStoreSender:
    provider: PushProvider = "rustore"

    def __init__(
        self,
        *,
        project_id: str,
        service_token: str,
        client: httpx.AsyncClient,
        clock: Clock = utc_now,
    ) -> None:
        self._url = SEND_URL_TEMPLATE.format(project_id=project_id)
        self._service_token = service_token
        self._client = client
        self._clock = clock

    def __repr__(self) -> str:
        return "RuStoreSender()"

    async def aclose(self) -> None:
        await self._client.aclose()

    async def send(self, message: PushMessage) -> SendResult:
        return await guarded("rustore", message.delivery_id, lambda: self._send(message))

    async def _send(self, message: PushMessage) -> SendResult:
        data = {key: str(value) for key, value in message.payload.to_wire().items()}
        body = {
            "message": {
                "token": message.token,
                "data": data,
                "android": {"ttl": f"{message.ttl_seconds}s"},
            }
        }
        response = await self._client.post(
            self._url, json=body, headers={"Authorization": f"Bearer {self._service_token}"}
        )
        if response.status_code == 200:
            return SendResult.ok()
        return self._map_error(response)

    def _map_error(self, response: httpx.Response) -> SendResult:
        body = json_object(response)
        status = body.get("status")
        code = safe_code(status)
        if code == "unknown":
            return fallback_by_status(response, self._clock)
        if status == "NOT_FOUND":
            return SendResult.invalid_token(code)
        if status == "INVALID_ARGUMENT":
            # The docs' example of a dead token is an INVALID_ARGUMENT that says so; any
            # other bad argument is our payload, which retrying cannot fix.
            if _says_token_is_invalid(body):
                return SendResult.invalid_token(code)
            return SendResult.fatal(code)
        if status in _RETRY_STATUSES:
            return SendResult.retry(code, retry_after(response, self._clock))
        if status in _FATAL_STATUSES:
            return SendResult.fatal(code)
        return fallback_by_status(response, self._clock)


def _says_token_is_invalid(body: dict[str, Any]) -> bool:
    message = body.get("message")
    return isinstance(message, str) and "token" in message.lower()
