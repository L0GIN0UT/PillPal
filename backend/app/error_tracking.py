"""Error tracker wiring (milestone 5.13, ADR 0017 section 10, ``rules/privacy.md``).

Initialized only when ``SENTRY_DSN`` is set, in the API and in the ARQ worker. What may leave
the process is errors: type, frames and scrubbed context, never an exception's text. Never
request bodies, query strings, cookies, local variables, breadcrumbs or user data.
"""

from __future__ import annotations

from typing import Any

import sentry_sdk
from sentry_sdk.integrations.logging import LoggingIntegration
from sentry_sdk.transport import Transport

from app.config import Settings
from app.observability import scrub_sentry_event

# Request parts that can carry medical data or credentials, dropped whole (not just by key).
_REQUEST_PARTS = ("data", "query_string", "cookies", "env")
# Of the request headers only these stay: the rest (authorization, cookies, forwarded addresses,
# custom headers) is not needed to find a bug.
_HEADER_ALLOWLIST = frozenset({"content-type", "content-length", "user-agent", "x-request-id"})


def _drop_request_parts(event: dict[str, Any]) -> None:
    request = event.get("request")
    if not isinstance(request, dict):
        return
    for part in _REQUEST_PARTS:
        request.pop(part, None)
    url = request.get("url")
    if isinstance(url, str):
        request["url"] = url.split("?", 1)[0]
    headers = request.get("headers")
    if isinstance(headers, dict):
        request["headers"] = {
            key: value for key, value in headers.items() if str(key).lower() in _HEADER_ALLOWLIST
        }


def _drop_free_text(event: dict[str, Any]) -> None:
    """Exception and log messages embed SQL parameters and DETAIL lines: keep types only."""
    for key in ("message", "logentry"):
        event.pop(key, None)
    exception = event.get("exception")
    values = exception.get("values") if isinstance(exception, dict) else None
    for value in values if isinstance(values, list) else []:
        if isinstance(value, dict):
            value.pop("value", None)


def _before_send(event: Any, hint: Any) -> Any:
    scrubbed = scrub_sentry_event(event, hint)
    if scrubbed is not None:
        _drop_request_parts(scrubbed)
        _drop_free_text(scrubbed)
    return scrubbed


def _before_send_transaction(event: Any, hint: Any) -> Any:
    scrubbed = _before_send(event, hint)
    if scrubbed is not None:
        # Span descriptions hold URLs (device tokens) and cache or Redis keys.
        scrubbed.pop("spans", None)
    return scrubbed


def init_error_tracking(settings: Settings, *, transport: Transport | None = None) -> bool:
    """Start the SDK if a DSN is configured; return whether it was started.

    ``transport`` exists for tests, which capture what would be sent.
    """
    if settings.sentry_dsn is None:
        return False
    sentry_sdk.init(
        dsn=settings.sentry_dsn.get_secret_value(),
        environment=settings.environment,
        release=settings.sentry_release,
        send_default_pii=False,
        include_local_variables=False,
        max_request_body_size="never",
        # No HTTP-client or log breadcrumbs: calls to providers carry tokens and codes.
        max_breadcrumbs=0,
        traces_sample_rate=settings.sentry_traces_sample_rate,
        before_send=_before_send,
        before_send_transaction=_before_send_transaction,
        # No sentry-trace or baggage header to push providers, identity providers or the catalog.
        trace_propagation_targets=[],
        # Our own logs are structured and never reach the SDK; free-text log records
        # must not become events either.
        integrations=[LoggingIntegration(level=None, event_level=None)],
        transport=transport,
    )
    return True
