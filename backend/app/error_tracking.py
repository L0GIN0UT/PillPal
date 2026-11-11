"""Error tracker wiring (milestone 5.13, ADR 0017 section 10, ``rules/privacy.md``).

Initialized only when ``SENTRY_DSN`` is set, in the API and in the ARQ worker. What may leave
the process is errors: type, frames and scrubbed context. Never request bodies, query strings,
cookies, local variables, breadcrumbs or user data.
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


def _drop_request_parts(event: dict[str, Any]) -> None:
    request = event.get("request")
    if isinstance(request, dict):
        for part in _REQUEST_PARTS:
            request.pop(part, None)
        url = request.get("url")
        if isinstance(url, str):
            request["url"] = url.split("?", 1)[0]


def _before_send(event: Any, hint: Any) -> Any:
    scrubbed = scrub_sentry_event(event, hint)
    if scrubbed is not None:
        _drop_request_parts(scrubbed)
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
        before_send_transaction=_before_send,
        # Our own logs are structured and never reach the SDK; free-text log records
        # must not become events either.
        integrations=[LoggingIntegration(level=None, event_level=None)],
        transport=transport,
    )
    return True
