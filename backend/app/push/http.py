"""Shared plumbing of the HTTP push senders: error bodies and transport failures.

Messages of ``httpx`` errors embed the request URL, and the APNs URL carries the device
token, so nothing here ever reads ``str(exc)``; a failure is its *type* and a code.
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime
from typing import Any

import httpx

from app.observability import get_logger
from app.push.base import SendResult, parse_retry_after

# httpx logs "HTTP Request: POST <url>" at INFO and the APNs URL carries the device token:
# the loggers are silenced whenever a sender is imported, whatever the root level is.
for _noisy in ("httpx", "httpcore", "hpack", "h2"):
    logging.getLogger(_noisy).setLevel(logging.WARNING)

TRANSPORT_ERROR = "transport_error"
_log = get_logger("pillpal.push")

Clock = Callable[[], datetime]


def utc_now() -> datetime:
    return datetime.now(UTC)


def json_object(response: httpx.Response) -> dict[str, Any]:
    """The JSON object body, or ``{}`` for anything else (HTML error pages, empty bodies)."""
    try:
        body = response.json()
    except ValueError:
        return {}
    return body if isinstance(body, dict) else {}


def retry_after(response: httpx.Response, clock: Clock) -> float | None:
    return parse_retry_after(response.headers.get("retry-after"), clock())


def http_code(status: int) -> str:
    return f"http_{status}"


def fallback_by_status(response: httpx.Response, clock: Clock) -> SendResult:
    """Unknown error: 5xx and 429 are worth retrying, anything else is a configuration problem."""
    status = response.status_code
    if status == 429 or status >= 500:
        return SendResult.retry(http_code(status), retry_after(response, clock))
    return SendResult.fatal(http_code(status))


async def guarded(
    provider: str, delivery_id: str, call: Callable[[], Awaitable[SendResult]]
) -> SendResult:
    """Run one provider call; a transport failure becomes ``RETRY`` and is logged by type."""
    try:
        return await call()
    except httpx.HTTPError as exc:
        _log.warning(
            "push_transport_error",
            provider=provider,
            delivery_id=delivery_id,
            exc_type=type(exc).__name__,
        )
        return SendResult.retry(TRANSPORT_ERROR)
